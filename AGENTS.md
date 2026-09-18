# Final Cut integration tests

- Run every Final Cut test inside the existing `Cutdown Integration.fcpbundle` library in this workspace. This is the user's required test location.
- A fresh checkout does not include the library. Before any live test, create an empty `Cutdown Integration.fcpbundle` at the workspace root as described in `docs/setup.md`; reuse an existing library at that exact path without replacing it. Never substitute another library.
- Use small, disposable test projects inside that library. Reference generated source media in place; avoid copied, optimized, and proxy media for these fixtures.
- Do not test in the user's other Final Cut libraries or projects.
- Reuse `build/swift` for sequential Swift builds. Remove redundant generated test caches when no process is using them; preserve source media, exported integration evidence, and the registered app bundles.
- Keep the documented integration status accurate. An effect loading or an analysis test passing does not establish that automatic timeline cuts work.
