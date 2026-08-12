"""
Tessera LibreOffice Document Service — Hybrid In-Process UNO

Runs inside the embedded CPython interpreter (LibreOffice vendored Python.framework).
Initializes the UNO runtime in-process via URE_BOOTSTRAP — NO soffice subprocess,
NO socket bridge. The embedded Python directly calls UNO C++ APIs via pyuno.

Architecture:
    Tessera Studio (Swift)
        -> EmbeddedPythonBridge (owns Python lifecycle)
              -> tessera_lo_service (this module, runs on GIL thread)
                    -> uno.py + pyuno.so (Python UNO bridge)
                          -> libmergedlo.dylib (in-process UNO runtime)
                                URE_BOOTSTRAP=libuuresolverlo.dylib
                                initializes UNO without subprocess

Bootstrap sequence:
    1. URE_BOOTSTRAP env var tells pyuno's C extension where to find
       libuuresolverlo.dylib (installed by setup-libreoffice-vendor.sh).
    2. Py_Initialize() triggers pyuno import which reads URE_BOOTSTRAP.
    3. pyuno loads libuuresolverlo.dylib -> discovers UNO registry files.
    4. UNO runtime initializes in-process: context, service manager, desktop.
    5. bridge_bootstrap_uno() returns the ready state.
    6. All subsequent calls use the in-process UNO context.

This module is called from Swift via EmbeddedPythonBridge.call().
All functions are synchronous. The GIL is held during execution.
"""

import sys
import os
import json
import traceback
from typing import Any, Optional, List, Dict

import uno
from com.sun.star.beans import PropertyValue


# ---------------------------------------------------------------------------
# Global UNO state — initialized once by bootstrap_uno()
# ---------------------------------------------------------------------------

# The in-process UNO component context. Set by bootstrap_uno().
_context: Any = None

# The UNO ServiceManager. Derived from _context after bootstrap.
_serviceManager: Any = None

# The UNO Desktop singleton. Derived from _context after bootstrap.
_desktop: Any = None

# Whether UNO has been bootstrapped in-process.
_isBootstrapped: bool = False

# Registry of open documents by handle (Python object id -> XComponent).
_openDocuments: Dict[int, Any] = {}


# ---------------------------------------------------------------------------
# UNO In-Process Bootstrap
# ---------------------------------------------------------------------------

def _makePropertyValue(name: str, value: Any) -> Any:
    """Creates a UNO PropertyValue."""
    prop = PropertyValue()
    prop.Name = name
    prop.Value = value
    return prop


def _makeProps(**kwargs) -> List[Any]:
    """Creates a list of PropertyValue objects from kwargs."""
    return [_makePropertyValue(k, v) for k, v in kwargs.items()]


def bootstrap_uno() -> Dict[str, Any]:
    """
    Bootstraps the UNO runtime in-process using URE_BOOTSTRAP.

    This is the hybrid alternative to spawning soffice --accept and connecting
    via socket. With URE_BOOTSTRAP set to the vendored libuuresolverlo.dylib,
    pyuno initializes the UNO C++ runtime directly inside the current process.

    Idempotent: subsequent calls return immediately if already bootstrapped.

    Returns:
        {"ok": True, "bootstrapped": True, "mode": "inprocess", "context": "<repr>"}
    """
    global _context, _serviceManager, _desktop, _isBootstrapped

    if _isBootstrapped:
        return {
            "ok": True,
            "bootstrapped": True,
            "mode": "inprocess",
            "reused": True,
            "context": repr(_context) if _context else "None",
        }

    # Get the local component context. When URE_BOOTSTRAP is set, this
    # returns the initialized UNO context with ServiceManager available.
    _context = uno.getComponentContext()

    if _context is None:
        raise LOConnectionError(
            "uno.getComponentContext() returned None. "
            "URE_BOOTSTRAP may not be set correctly. "
            "Ensure EmbeddedPythonBridge configured PYTHONHOME, "
            "URE_BOOTSTRAP, UNO_PATH, and PYTHONPATH before import."
        )

    # Resolve the ServiceManager from the context.
    resolver = _context.ServiceManager.createInstanceWithContext(
        "com.sun.star.bridge.UnoUrlResolver", _context
    )

    # In in-process mode, resolver may be None or return the same context.
    # Try to get the ServiceManager directly from the context.
    _serviceManager = getattr(_context, "ServiceManager", None)
    if _serviceManager is None:
        raise LOConnectionError(
            "UNO context has no ServiceManager. "
            "URE bootstrap may have failed to fully initialize the runtime."
        )

    # Create the Desktop singleton — this is the UNO application root.
    _desktop = _serviceManager.createInstanceWithContext(
        "com.sun.star.frame.Desktop", _context
    )

    if _desktop is None:
        raise LOConnectionError(
            "Could not create com.sun.star.frame.Desktop. "
            "UNO runtime may not be fully initialized."
        )

    _isBootstrapped = True

    return {
        "ok": True,
        "bootstrapped": True,
        "mode": "inprocess",
        "reused": False,
        "context": repr(_context),
        "serviceManager": repr(_serviceManager),
        "desktop": repr(_desktop),
    }


def dispose() -> Dict[str, Any]:
    """
    Disposes all open documents and resets the UNO context.

    Call this before shutting down the embedded Python interpreter to cleanly
    release UNO resources. Idempotent.

    Returns:
        {"ok": True, "documents_closed": N}
    """
    global _context, _serviceManager, _desktop, _isBootstrapped, _openDocuments

    closed_count = 0
    for handle, doc in list(_openDocuments.items()):
        try:
            doc.close(True)
            closed_count += 1
        except Exception:
            pass
    _openDocuments.clear()

    _desktop = None
    _serviceManager = None
    _context = None
    _isBootstrapped = False

    return {"ok": True, "documents_closed": closed_count}


# ---------------------------------------------------------------------------
# Document Operations
# ---------------------------------------------------------------------------

def _ensureBootstrap() -> None:
    """Raises LOConnectionError if UNO is not bootstrapped."""
    if not _isBootstrapped or _context is None or _serviceManager is None:
        raise LOConnectionError(
            "UNO not bootstrapped. Call bridge_bootstrap_uno() first."
        )


def open_document(inputPath: str, format: Optional[str] = None) -> Dict[str, Any]:
    """
    Opens a document using the in-process UNO desktop.

    No port parameter — UNO runs in-process, not via socket.

    Args:
        inputPath: Absolute filesystem path to the document.
        format:    Optional format hint. One of: "docx", "xlsx", "pptx",
                   "odt", "ods", "odp", "rtf", "html", "txt", "auto".
                   If None, defaults to "auto" (detect from extension).

    Returns:
        {"ok": True, "handle": int, "docType": str, "path": str}
        The handle is a Python object id used for subsequent operations.
    """
    _ensureBootstrap()

    if format is None:
        format = "auto"

    # Detect format from extension if "auto"
    if format == "auto":
        ext = os.path.splitext(inputPath)[1].lower().lstrip(".")
        formatMap = {
            "docx": "MS Word 2007 XML",
            "doc": "MS Word 2007 XML",
            "xlsx": "Calc MS Excel 2007 XML",
            "xls": "MS Excel 2007 XML",
            "pptx": "Impress MS PowerPoint 2007 XML",
            "ppt": "MS PowerPoint 2007 XML",
            "odt": "writer8",
            "ods": "calc8",
            "odp": "impress8",
            "rtf": "Rich Text Format",
            "html": "HTML (StarWriter)",
            "txt": "Text (StarWriter)",
        }
        filterName = formatMap.get(ext, "")
    else:
        filterName = format

    # Use the desktop singleton created during bootstrap.
    desktop = _desktop
    if desktop is None:
        raise LOServiceError("Desktop singleton not available")

    url = uno.systemPathToFileUrl(os.path.abspath(inputPath))

    props = _makeProps(
        Hidden=True,
        ReadOnly=False,
        MacroExecutionMode=0,
        FilterName=filterName,
    )

    try:
        component = desktop.loadComponentFromURL(url, "_blank", 0, tuple(props))
    except Exception as e:
        raise LOServiceError(f"Failed to open {inputPath}: {e}")

    if component is None:
        raise LOServiceError(f"loadComponentFromURL returned None for {inputPath}")

    # Detect document type
    docType = _detect_document_type(component)

    # Store in registry — handle is the Python object id
    handle = id(component)
    _openDocuments[handle] = component

    return {
        "ok": True,
        "handle": handle,
        "docType": docType,
        "path": inputPath,
    }


def _detect_document_type(component: Any) -> str:
    """Detects the document type from its supported service names."""
    try:
        supported = component.SupportedServiceNames
        if supported:
            for svc in supported:
                svc_lower = svc.lower()
                if "writer" in svc_lower:
                    return "writer"
                if "calc" in svc_lower:
                    return "calc"
                if "impress" in svc_lower:
                    return "impress"
    except Exception:
        pass
    return "unknown"


def close_document(handle: int) -> Dict[str, Any]:
    """
    Closes a document by handle.

    Args:
        handle: The integer handle returned by open_document.

    Returns:
        {"ok": True}
    """
    doc = _openDocuments.pop(handle, None)
    if doc is None:
        return {"ok": True, "already_closed": True}
    try:
        doc.close(True)
    except Exception:
        pass
    return {"ok": True}


def save_document(
    handle: int,
    outputPath: str,
    format: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Saves a document to a new path / format.

    Args:
        handle:      Integer handle from open_document.
        outputPath:  Destination filesystem path.
        format:     Optional export format filter. If None, infers from extension.

    Returns:
        {"ok": True, "outputPath": outputPath}
    """
    doc = _openDocuments.get(handle)
    if doc is None:
        raise LODocumentError(f"No open document with handle {handle}")

    if format is None:
        ext = os.path.splitext(outputPath)[1].lower().lstrip(".")
        formatMap = {
            "docx": "MS Word 2007 XML",
            "xlsx": "Calc MS Excel 2007 XML",
            "pptx": "Impress MS PowerPoint 2007 XML",
            "odt": "writer8",
            "ods": "calc8",
            "odp": "impress8",
            "rtf": "Rich Text Format",
            "pdf": "writer_pdf_Export",
        }
        filterName = formatMap.get(ext, "")
    else:
        filterName = format

    url = uno.systemPathToFileUrl(os.path.abspath(outputPath))
    props = _makeProps(
        FilterName=filterName,
        Overwrite=True,
    )

    try:
        doc.storeToURL(url, tuple(props))
    except Exception as e:
        raise LOServiceError(f"Failed to save {outputPath}: {e}")

    return {"ok": True, "outputPath": outputPath}


# ---------------------------------------------------------------------------
# Writer Operations
# ---------------------------------------------------------------------------

def writer_get_text(handle: int) -> str:
    """Returns all text from a Writer document as a single string."""
    doc = _openDocuments.get(handle)
    if doc is None:
        raise LODocumentError(f"No open document with handle {handle}")
    try:
        return doc.Text.String
    except AttributeError:
        raise LOServiceError(f"Document {handle} is not a Writer document")


def writer_get_paragraphs(handle: int) -> List[Dict[str, Any]]:
    """
    Returns paragraphs with style and text.

    Returns:
        List of {"index": int, "style": str, "text": str}
    """
    doc = _openDocuments.get(handle)
    if doc is None:
        raise LODocumentError(f"No open document with handle {handle}")
    try:
        text = doc.Text
        cursor = text.createTextCursor()
        cursor.gotoStart(False)
        paras = []
        i = 0
        while True:
            para = cursor.getParagraph()
            if para is None:
                break
            style = getattr(para, "PageStyleName", "Unknown")
            paraText = getattr(para, "String", "") or ""
            paras.append({
                "index": i,
                "style": str(style),
                "text": str(paraText),
            })
            i += 1
            if not cursor.gotoNextParagraph(False):
                break
        return paras
    except Exception as e:
        raise LOServiceError(f"Failed to get paragraphs: {e}")


def writer_set_paragraph_style(
    handle: int,
    paragraphIndex: int,
    styleName: str,
) -> Dict[str, Any]:
    """Applies a named paragraph style to a paragraph."""
    doc = _openDocuments.get(handle)
    if doc is None:
        raise LODocumentError(f"No open document with handle {handle}")
    try:
        text = doc.Text
        cursor = text.createTextCursor()
        cursor.gotoStart(False)
        for _ in range(paragraphIndex):
            if not cursor.gotoNextParagraph(False):
                raise LODocumentError(f"Paragraph {paragraphIndex} not found")
        cursor.gotoNextParagraph(True)
        cursor.ParaStyleName = styleName
        return {"ok": True, "paragraph": paragraphIndex, "style": styleName}
    except LODocumentError:
        raise
    except Exception as e:
        raise LOServiceError(f"Failed to set paragraph style: {e}")


def writer_insert_text(handle: int, text: str) -> Dict[str, Any]:
    """Inserts text at the end of the document."""
    doc = _openDocuments.get(handle)
    if doc is None:
        raise LODocumentError(f"No open document with handle {handle}")
    try:
        cursor = doc.Text.createTextCursor()
        cursor.gotoEnd(False)
        cursor.insertString(text, False)
        return {"ok": True, "inserted": len(text)}
    except Exception as e:
        raise LOServiceError(f"Failed to insert text: {e}")


# ---------------------------------------------------------------------------
# Calc Operations
# ---------------------------------------------------------------------------

def calc_get_sheet_names(handle: int) -> List[str]:
    """Returns all sheet names in a Calc document."""
    doc = _openDocuments.get(handle)
    if doc is None:
        raise LODocumentError(f"No open document with handle {handle}")
    try:
        sheets = doc.Sheets
        return [sheets.getElementNames()[i] for i in range(sheets.getCount())]
    except AttributeError:
        raise LOServiceError(f"Document {handle} is not a Calc document")
    except Exception as e:
        raise LOServiceError(f"Failed to get sheet names: {e}")


def calc_read_cells(
    handle: int,
    sheetName: str,
    range_: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Reads cell values from a Calc sheet.

    Args:
        handle:     Document handle.
        sheetName:  Name of the sheet.
        range_:    Optional cell range (e.g. "A1:C10"). Defaults to "A1:AD1000".

    Returns:
        {"ok": True, "cells": {"A1": value, ...}, "formulae": {"A1": "=SUM(...)"}}
    """
    doc = _openDocuments.get(handle)
    if doc is None:
        raise LODocumentError(f"No open document with handle {handle}")
    try:
        sheets = doc.Sheets
        sheet = sheets.getByName(sheetName)
    except AttributeError:
        raise LOServiceError(f"Document {handle} is not a Calc document")
    except Exception:
        raise LODocumentError(f"Sheet '{sheetName}' not found in document {handle}")

    try:
        if range_ is not None:
            cellRange = sheet.getCellRangeByName(range_)
        else:
            cellRange = sheet.getCellRangeByName("A1:AD1000")

        rows = cellRange.Rows.Count
        cols = cellRange.Columns.Count
        cells = {}
        formulae = {}

        for row in range(rows):
            for col in range(cols):
                cell = cellRange.getCellByPosition(col, row)
                addr = f"{_col_index_to_letter(col + 1)}{row + 1}"
                try:
                    val = cell.String
                    if val:
                        cells[addr] = val
                except Exception:
                    pass
                try:
                    formula = cell.Formula
                    if formula and formula.startswith("="):
                        formulae[addr] = formula
                except Exception:
                    pass

        return {"ok": True, "cells": cells, "formulae": formulae}
    except Exception as e:
        raise LOServiceError(f"Failed to read cells: {e}")


def calc_write_cell(
    handle: int,
    sheetName: str,
    cellAddr: str,
    value: Any,
    formula: Optional[str] = None,
) -> Dict[str, Any]:
    """Writes a value or formula to a single cell."""
    doc = _openDocuments.get(handle)
    if doc is None:
        raise LODocumentError(f"No open document with handle {handle}")
    try:
        sheets = doc.Sheets
        sheet = sheets.getByName(sheetName)
        cell = sheet.getCellRangeByName(cellAddr)
    except Exception as e:
        raise LODocumentError(f"Cannot access cell {cellAddr} in '{sheetName}': {e}")
    try:
        if formula is not None:
            cell.Formula = formula
        elif isinstance(value, str):
            cell.setString(value)
        elif isinstance(value, (int, float)):
            cell.setValue(value)
        else:
            cell.setString(str(value))
        return {"ok": True, "cell": cellAddr, "value": value}
    except Exception as e:
        raise LOServiceError(f"Failed to write to cell {cellAddr}: {e}")


def _col_index_to_letter(n: int) -> str:
    """Converts 1-based column index to letter (1->A, 27->AA)."""
    result = ""
    while n > 0:
        n, rem = divmod(n - 1, 26)
        result = chr(65 + rem) + result
    return result


# ---------------------------------------------------------------------------
# Impress Operations
# ---------------------------------------------------------------------------

def impress_get_slides(handle: int) -> List[Dict[str, Any]]:
    """Returns slide titles and notes."""
    doc = _openDocuments.get(handle)
    if doc is None:
        raise LODocumentError(f"No open document with handle {handle}")
    try:
        slides = doc.getDrawPages()
        result = []
        for i in range(slides.getCount()):
            slide = slides.getByIndex(i)
            title = ""
            try:
                shapes = slide.getShapes()
                for s in range(shapes.getCount()):
                    shape = shapes.getByIndex(s)
                    if hasattr(shape, "Name") and "title" in shape.Name.lower():
                        try:
                            title = shape.Text.Text.String
                        except Exception:
                            pass
            except Exception:
                pass
            result.append({
                "index": i,
                "title": str(title) if title else f"Slide {i+1}",
            })
        return result
    except AttributeError:
        raise LOServiceError(f"Document {handle} is not an Impress document")
    except Exception as e:
        raise LOServiceError(f"Failed to get slides: {e}")


# ---------------------------------------------------------------------------
# Error Types
# ---------------------------------------------------------------------------

class LOConnectionError(Exception):
    """Raised when UNO in-process bootstrap fails."""
    pass


class LOServiceError(Exception):
    """Raised when a LibreOffice service call fails."""
    pass


class LODocumentError(Exception):
    """Raised when a document operation fails."""
    pass


# ---------------------------------------------------------------------------
# Swift Bridge Entry Points
# All return JSON strings for the EmbeddedPythonBridge.call() protocol.
# ---------------------------------------------------------------------------

def bridge_bootstrap_uno() -> str:
    """
    Swift-callable: bootstraps UNO in-process.
    Returns JSON: {"ok": True, "bootstrapped": True, "mode": "inprocess", ...}
    """
    try:
        result = bootstrap_uno()
        return json.dumps(result)
    except Exception as e:
        return json.dumps({
            "ok": False,
            "error": str(e),
            "trace": traceback.format_exc(),
        })


def bridge_dispose() -> str:
    """
    Swift-callable: disposes all documents and resets UNO context.
    Returns JSON: {"ok": True, "documents_closed": N}
    """
    try:
        result = dispose()
        return json.dumps(result)
    except Exception as e:
        return json.dumps({
            "ok": False,
            "error": str(e),
            "trace": traceback.format_exc(),
        })


def bridge_open(inputPath: str, format: Optional[str] = None) -> str:
    """
    Swift-callable: opens a document (in-process, no port needed).
    Returns JSON: {"ok": True, "handle": int, "docType": str, "path": str}
    """
    try:
        result = open_document(inputPath, format)
        return json.dumps(result)
    except Exception as e:
        return json.dumps({
            "ok": False,
            "error": str(e),
            "trace": traceback.format_exc(),
        })


def bridge_close(handle: int) -> str:
    """Swift-callable: closes a document. Returns JSON."""
    try:
        result = close_document(handle)
        return json.dumps(result)
    except Exception as e:
        return json.dumps({
            "ok": False,
            "error": str(e),
            "trace": traceback.format_exc(),
        })


def bridge_save(
    handle: int,
    outputPath: str,
    format: Optional[str] = None,
) -> str:
    """Swift-callable: saves a document. Returns JSON."""
    try:
        result = save_document(handle, outputPath, format)
        return json.dumps(result)
    except Exception as e:
        return json.dumps({
            "ok": False,
            "error": str(e),
            "trace": traceback.format_exc(),
        })


def bridge_writer_get_text(handle: int) -> str:
    """Swift-callable: gets Writer text. Returns JSON."""
    try:
        text = writer_get_text(handle)
        return json.dumps({"ok": True, "text": text})
    except Exception as e:
        return json.dumps({
            "ok": False,
            "error": str(e),
            "trace": traceback.format_exc(),
        })


def bridge_calc_get_cells(
    handle: int,
    sheetName: str,
    range_: Optional[str] = None,
) -> str:
    """Swift-callable: reads Calc cells. Returns JSON."""
    try:
        result = calc_read_cells(handle, sheetName, range_)
        return json.dumps(result)
    except Exception as e:
        return json.dumps({
            "ok": False,
            "error": str(e),
            "trace": traceback.format_exc(),
        })


def bridge_impress_get_slides(handle: int) -> str:
    """Swift-callable: gets Impress slides. Returns JSON."""
    try:
        slides = impress_get_slides(handle)
        return json.dumps({"ok": True, "slides": slides})
    except Exception as e:
        return json.dumps({
            "ok": False,
            "error": str(e),
            "trace": traceback.format_exc(),
        })
