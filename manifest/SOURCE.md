# Vendored device manifest

- File: `oneplus_ace_race_v.xml`
- Source: `https://github.com/Numbersf/kernel_manifest`, branch `oneplus/mt6895`
- Commit: `b4ad3a1749b700d81603b67b48962b661fb60e5e`
- Reason: `OnePlusOSS/kernel_manifest` does not publish `oneplus_ace_race_v.xml`.
  The XML is a small list of OnePlusOSS/CLO project URLs; vendoring it keeps the
  build free of a runtime dependency on a third-party manifest repository.
- The projects themselves are fetched from `OnePlusOSS` and `git.codelinaro.org`.

Refresh procedure when a new stock boot image is available: update this XML and
the `README.md` build line, then re-run `tools/extract_stock_baseline.py` and
update `baseline/`.
