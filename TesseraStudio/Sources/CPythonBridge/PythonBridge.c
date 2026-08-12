// PythonBridge.c - defines all bridge functions as regular C functions
// with external linkage, so Swift's @_silgen_name can link against them.
//
// PythonBridge.h provides the declarations (so Python struct types are visible
// to the Swift bridging layer). This .c file provides the actual implementations.
//
// Key insight: `static inline` and `extern inline` both fail to emit external
// symbols in practice. The only reliable way to get a linkable symbol is a
// regular (non-inline, non-static) function definition.

#include "CPythonBridge/PythonBridge.h"

// ---------------------------------------------------------------------------
// Sentinel values
// ---------------------------------------------------------------------------
PyObject *bridge_PyNone(void)  { return Py_None; }
PyObject *bridge_PyTrue(void)  { return Py_True; }
PyObject *bridge_PyFalse(void) { return Py_False; }

// ---------------------------------------------------------------------------
// Type-check macros -> linkable functions
// ---------------------------------------------------------------------------
int bridge_PyDict_Check(PyObject *op)         { return PyDict_Check(op); }
int bridge_PyDict_CheckExact(PyObject *op)     { return PyDict_CheckExact(op); }
int bridge_PyList_Check(PyObject *op)         { return PyList_Check(op); }
int bridge_PyList_CheckExact(PyObject *op)     { return PyList_CheckExact(op); }
int bridge_PyTuple_Check(PyObject *op)          { return PyTuple_Check(op); }
int bridge_PyTuple_CheckExact(PyObject *op)     { return PyTuple_CheckExact(op); }
int bridge_PyFloat_Check(PyObject *op)         { return PyFloat_Check(op); }
int bridge_PyFloat_CheckExact(PyObject *op)    { return PyFloat_CheckExact(op); }
int bridge_PyLong_Check(PyObject *op)          { return PyLong_Check(op); }
int bridge_PyLong_CheckExact(PyObject *op)     { return PyLong_CheckExact(op); }
int bridge_PyUnicode_Check(PyObject *op)      { return PyUnicode_Check(op); }
int bridge_PyUnicode_CheckExact(PyObject *op)  { return PyUnicode_CheckExact(op); }
int bridge_PyBool_Check(PyObject *op)          { return PyBool_Check(op); }

// PyList_SET_ITEM / PyList_GET_ITEM — macros (no external symbols)
int bridge_PyList_SET_ITEM(PyObject *l, Py_ssize_t i, PyObject *o) {
    ((PyListObject *)(l))->ob_item[i] = o;
    return 0;
}
PyObject *bridge_PyList_GET_ITEM(PyObject *l, Py_ssize_t i) {
    return ((PyListObject *)(l))->ob_item[i];
}

// ---------------------------------------------------------------------------
// Removed Python 3.14 APIs -> new equivalents
// ---------------------------------------------------------------------------
PyObject *bridge_PyErr_ExceptionType(void) {
    PyObject *exc = PyErr_GetRaisedException();
    if (!exc) return NULL;
    PyObject *type = PyTuple_GetItem(exc, 0);
    PyObject *result = Py_NewRef(type);
    Py_DECREF(exc);
    return result;
}

PyObject *bridge_PyErr_ExceptionValue(void) {
    PyObject *exc = PyErr_GetRaisedException();
    if (!exc) return NULL;
    PyObject *value = PyTuple_GetItem(exc, 1);
    PyObject *result = Py_NewRef(value);
    Py_DECREF(exc);
    return result;
}

PyObject *bridge_PyErr_Traceback(void) {
    PyObject *exc = PyErr_GetRaisedException();
    if (!exc) return NULL;
    PyObject *tb = PyTuple_GetItem(exc, 2);
    PyObject *result = Py_NewRef(tb);
    Py_DECREF(exc);
    return result;
}

// ---------------------------------------------------------------------------
// PyTuple_SET_ITEM — macro workaround
// ---------------------------------------------------------------------------
int bridge_PyTuple_SET_ITEM(PyObject *t, Py_ssize_t i, PyObject *o) {
    ((PyTupleObject *)(t))->ob_item[i] = o;
    return 0;
}
