#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, Ghostty-iOS, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        [-skip-testing GhosttyUITests]
    } else {
        []
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($build_dir)"
        ...$skip_testing
        $action)

    let build_exit = $env.LAST_EXIT_CODE
    if $build_exit != 0 {
        exit $build_exit
    }

    # Xcode's local configurations use an ad-hoc identity while linking. The
    # resulting cdhash changes after every build, which makes macOS treat each
    # launch as a new app for microphone and accessibility permissions. Always
    # replace it with GaiTerm's long-lived local identity before handing the
    # bundle to the developer.
    let should_stabilize_identity = (
        $action == "build"
        and $scheme == "Ghostty"
        and $configuration in ["Debug", "ReleaseLocal"]
    )
    if $should_stabilize_identity {
        let app = ($build_dir | path join $configuration | path join "GaiTerm.app")
        let entitlements = if $configuration == "ReleaseLocal" {
            ($env.FILE_PWD | path join "GhosttyReleaseLocal.entitlements")
        } else {
            ($env.FILE_PWD | path join "GhosttyDebug.entitlements")
        }

        if not ($app | path exists) {
            error make {msg: $"Build succeeded but app bundle is missing: ($app)"}
        }

        print $"Stabilizing GaiTerm identity for ($configuration)..."
        (^/usr/bin/codesign
            --force
            --deep
            --options runtime
            --entitlements $entitlements
            --sign "GaiTerm Self-Signed"
            $app)
        if $env.LAST_EXIT_CODE != 0 {
            error make {msg: "Stable GaiTerm code signing failed"}
        }

        ^/usr/bin/codesign --verify --deep --strict $app
        if $env.LAST_EXIT_CODE != 0 {
            error make {msg: "Stable GaiTerm signature verification failed"}
        }
    }
}
