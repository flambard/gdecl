;;;; Utilities that depend on nothing else in gdecl, each in a package of its
;;;; own: GDECL-JSON, a small JSON reader for extension_api.json, used when the
;;;; code is compiled.
;;;; See Layers in CLAUDE.md.

(defpackage #:gdecl-json
  (:documentation "A small JSON reader, for extension_api.json")
  (:use #:cl)
  (:export #:parse-json
           #:read-json-file
           #:json-get))
