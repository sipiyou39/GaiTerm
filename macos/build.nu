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

    let should_stabilize_identity = (
        $action in ["build", "test"]
        and $scheme == "Ghostty"
        and $configuration in ["Debug", "ReleaseLocal"]
    )
    let sign_identity = if $configuration == "Debug" {
        ($env.TEDDYCLI_DEBUG_SIGN_IDENTITY?
            | default "Apple Development: sipiyou@icloud.com (GVZY3J5T4T)")
    } else {
        ($env.TEDDYCLI_SIGN_ID?
            | default "Developer ID Application: younes boukobaa (JPC779B3N5)")
    }
    let sign_team = if $configuration == "Debug" {
        ($env.TEDDYCLI_DEBUG_TEAM_ID? | default "4NT6BRHMPJ")
    } else {
        ($env.TEDDYCLI_RELEASE_TEAM_ID? | default "JPC779B3N5")
    }
    let signing_settings = if $should_stabilize_identity {
        [
            "CODE_SIGN_STYLE=Manual"
            $"DEVELOPMENT_TEAM=($sign_team)"
            $"CODE_SIGN_IDENTITY=($sign_identity)"
        ]
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
        ...$signing_settings
        ...$skip_testing
        $action)

    let build_exit = $env.LAST_EXIT_CODE
    if $build_exit != 0 {
        exit $build_exit
    }

    # Xcode receives the stable identity above so it never registers an ad-hoc
    # Teddy CLI bundle with LaunchServices. Sign the completed bundle once more
    # as a defensive finalization step, then register that exact result.
    if $should_stabilize_identity {
        let app = ($build_dir | path join $configuration | path join "Teddy CLI.app")
        let entitlements = if $configuration == "ReleaseLocal" {
            ($env.FILE_PWD | path join "GhosttyReleaseLocal.entitlements")
        } else {
            ($env.FILE_PWD | path join "GhosttyDebug.entitlements")
        }
        if not ($app | path exists) {
            error make {msg: $"Build succeeded but app bundle is missing: ($app)"}
        }

        print $"Signing Teddy CLI ($configuration) with '($sign_identity)'..."
        (^/usr/bin/codesign
            --force
            --deep
            --options runtime
            --entitlements $entitlements
            --sign $sign_identity
            $app)
        if $env.LAST_EXIT_CODE != 0 {
            error make {msg: "Stable Teddy CLI code signing failed"}
        }

        ^/usr/bin/codesign --verify --deep --strict $app
        if $env.LAST_EXIT_CODE != 0 {
            error make {msg: "Stable Teddy CLI signature verification failed"}
        }

        # Register the finalized bundle explicitly so LaunchServices and macOS
        # privacy services resolve the same stable identity after every build.
        let launch_services = "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
        (^$launch_services -f -R -trusted $app)
        if $env.LAST_EXIT_CODE != 0 {
            error make {msg: "Stable Teddy CLI LaunchServices registration failed"}
        }
    }
}
