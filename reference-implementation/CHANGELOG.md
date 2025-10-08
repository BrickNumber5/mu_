# mu\_ Reference Implementation Changelog

Entries in this log are in reverse chronological order, this means that the
changes introduced in the most recent version are always at the top of the
document.

This document only tracks the mu\_ reference implementation(s), other parts of
the mu\_ project are only tracked where they affect the implementation(s).

## `r0.3i1` --- 2025-10-08

  * Update to `r0.3` of the spec
  * `mu_.mjs` now requires `mu_.wasm` to be in the same directory as it instead
    of at the base url

## `r0.2i1` --- 2025-09-24

  * Original public version of `mu_.wat` and `mu_.mjs`, the reference
    implementation and first complete mu\_ implementation.
  * Implemented `r0.2` of the specification.
    * In general, reference implementation versions start with the
      specification revision they implement, followed by an `i`, followed by an
      implementation-specific version number.
      
      I don't necessarily recommend that other mu\_ implementations follow this
      schema, but as the reference implementation is intended simply to follow
      the specification as closely as possible and is managed as part of the
      same project as the specification (being embedded into the specification)
      it makes sense to synchronize its version numbers with the specification.
