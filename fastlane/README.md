fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload to TestFlight. Brand-new app: TestFlight only, no App Store submit.

### ios refresh_profiles

```sh
[bundle exec] fastlane ios refresh_profiles
```

One-time: regenerate the App Store signing profile after a capability/entitlement change (e.g. adding Sign in with Apple). Read-write: it re-creates the profile from the App ID's current capabilities and pushes it to the certs repo. Needs MATCH_PASSWORD + git write access.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
