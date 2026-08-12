// PythonBridge.h - declarations for Swift @_silgen_name imports.
//
// This header provides C declarations so that Swift code can #include it and
// see the Python type definitions (PyObject etc.). The actual symbol
// definitions are compiled from PythonBridge.c as regular (non-inline)
// functions with external linkage.
//
// Background:
//   Python's C API uses three categories of non-linkable symbols:
//   (1) Macros: PyDict_Check, PyFloat_Check, PyList_Check, PyTuple_SET_ITEM,
//       Py_INCREF, Py_DECREF, etc. These expand inline and have no .o entry.
//   (2) Renamed globals: Py_None/True/False are &(struct _object).__None__
//       in Python 3.14 (__Py_NoneStruct etc.), not _Py_None.
//   (3) Removed APIs: PyErr_ExceptionType/Value/Traceback were removed
//       in Python 3.14 in favour of PyErr_GetRaisedException().
//
// Strategy: all bridge functions are compiled as regular C functions in
// PythonBridge.c. This header declares them so the Python struct types
// are visible to Swift's C bridging layer.

#ifndef PYTHON_BRIDGE_H
#define PYTHON_BRIDGE_H

#include <Python.h>

#if defined(__GNUC__)
#pragma GCC visibility push(default)
#endif

// ---------------------------------------------------------------------------
// Sentinel values
// ---------------------------------------------------------------------------
extern PyObject *bridge_PyNone(void);
extern PyObject *bridge_PyTrue(void);
extern PyObject *bridge_PyFalse(void);

// ---------------------------------------------------------------------------
// Type-check macros -> linkable functions
// ---------------------------------------------------------------------------
extern int bridge_PyDict_Check(PyObject *op);
extern int bridge_PyDict_CheckExact(PyObject *op);
extern int bridge_PyList_Check(PyObject *op);
extern int bridge_PyList_CheckExact(PyObject *op);
extern int bridge_PyTuple_Check(PyObject *op);
extern int bridge_PyTuple_CheckExact(PyObject *op);
extern int bridge_PyFloat_Check(PyObject *op);
extern int bridge_PyFloat_CheckExact(PyObject *op);
extern int bridge_PyLong_Check(PyObject *op);
extern int bridge_PyLong_CheckExact(PyObject *op);
extern int bridge_PyUnicode_Check(PyObject *op);
extern int bridge_PyUnicode_CheckExact(PyObject *op);
extern int bridge_PyBool_Check(PyObject *op);

// PyList_SET_ITEM / PyList_GET_ITEM — macros (no external symbols)
extern int bridge_PyList_SET_ITEM(PyObject *l, Py_ssize_t i, PyObject *o);
extern PyObject *bridge_PyList_GET_ITEM(PyObject *l, Py_ssize_t i);

// ---------------------------------------------------------------------------
// Removed Python 3.14 APIs -> new equivalents
// ---------------------------------------------------------------------------
extern PyObject *bridge_PyErr_ExceptionType(void);
extern PyObject *bridge_PyErr_ExceptionValue(void);
extern PyObject *bridge_PyErr_Traceback(void);

// PyTuple_SET_ITEM — macro workaround
extern int bridge_PyTuple_SET_ITEM(PyObject *t, Py_ssize_t i, PyObject *o);

#if defined(__GNUC__)
#pragma GCC visibility pop
#endif

#endif // PYTHON_BRIDGE_H
