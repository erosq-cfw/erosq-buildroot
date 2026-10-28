<!-- Release notes template: ci/release fills ${TAG}, ${FWVER}, ${PINS}. -->
# EROS Q custom firmware ${TAG}

Firmware version `${FWVER}`.

## Supported devices

The firmware targets the Rockbox "hw4" EROS Q hardware class.

| Device | Hardware versions | Status |
|---|---|---|
| Aigo EROS Q | V2.2 – V2.3 | Tested (on an EROS Q, hw4) |
| Hifiwalker H2 | V1.9 – V2.3 | Expected to work (hw4), untested |
| Surfans F20 | V3.4 – V3.5 | Expected to work (hw4), untested |

Hardware classes as listed by the Rockbox project.

> **Warning:** other hardware versions (hw1–hw3, and anything not listed
> above) are **not supported**. Check your device's hardware version before
> installing, and keep the stock firmware `.upt` for your device so you can
> restore it.

## Install / update

<!-- TODO step 10: install/update steps, taken from the installer docs (not written yet) -->
- **Checksums:** `SHA256SUMS`, signed as `SHA256SUMS.sig`.

## Sources

Built by GitHub Actions from these pins:

```
${PINS}
```

Source tarballs and licence information: `legal-info` assets. Wi-Fi/Bluetooth chip firmware comes unmodified from the stock image via erosq-firmware; it has no licence and is not covered by MIT.
