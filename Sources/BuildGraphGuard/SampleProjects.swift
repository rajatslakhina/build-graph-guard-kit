import Foundation

/// Realistic project files used by the demo app and by the test suite.
///
/// These are *fixtures*, not documentation. The tests assert against the same
/// strings the demo renders, so a scenario that stops producing the finding its
/// title advertises fails CI rather than quietly becoming a screen full of nothing.
public enum SampleProjects {

    // MARK: - xcproj

    /// The baseline: a small storefront app, one test bundle, one pinned dependency.
    public static let storefrontBaseline = """
    {
      "schema-version": 1,
      "name": "Storefront",
      "build-settings": {
        "SWIFT_VERSION": "6.0",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "ENABLE_USER_SCRIPT_SANDBOXING": true,
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]": "DEBUG"
      },
      "targets": [
        {
          "name": "Storefront",
          "product-type": "com.apple.product-type.application",
          "build-settings": {
            "CODE_SIGN_IDENTITY": "Apple Development",
            "DEVELOPMENT_TEAM": "AB12CD34EF"
          },
          "package-product-dependencies": ["CheckoutKit"]
        },
        {
          "name": "StorefrontTests",
          "product-type": "com.apple.product-type.bundle.unit-test",
          "build-settings": {}
        }
      ],
      "files": [
        {
          "group": "Storefront",
          "children": [
            { "path": "StorefrontApp.swift", "target-membership": ["Storefront"] },
            {
              "group": "Checkout",
              "children": [
                { "path": "CartModel.swift", "target-membership": ["Storefront", "StorefrontTests"] }
              ]
            }
          ]
        },
        {
          "group": "StorefrontTests",
          "children": [
            { "path": "CartModelTests.swift", "target-membership": ["StorefrontTests"] }
          ]
        }
      ],
      "package-dependencies": [
        {
          "identity": "checkout-kit",
          "url": "https://github.com/example-org/checkout-kit.git",
          "requirement": { "kind": "upToNextMajorVersion", "minimum-version": "2.4.0" }
        }
      ]
    }
    """

    /// The headline case: an agent asked to "add the promo code screen" does that,
    /// and also turns off script sandboxing and adds a Release-only signing override.
    ///
    /// The signing edit is the interesting one. The unconditioned `CODE_SIGN_IDENTITY`
    /// is untouched, so a reviewer scanning the Debug column sees nothing; only the
    /// *effective* Release value moves.
    public static let storefrontAgentEdit = """
    {
      "schema-version": 1,
      "name": "Storefront",
      "build-settings": {
        "SWIFT_VERSION": "6.0",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "ENABLE_USER_SCRIPT_SANDBOXING": false,
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]": "DEBUG"
      },
      "targets": [
        {
          "name": "Storefront",
          "product-type": "com.apple.product-type.application",
          "build-settings": {
            "CODE_SIGN_IDENTITY": "Apple Development",
            "CODE_SIGN_IDENTITY[config=Release]": "-",
            "DEVELOPMENT_TEAM": "AB12CD34EF"
          },
          "package-product-dependencies": ["CheckoutKit"]
        },
        {
          "name": "StorefrontTests",
          "product-type": "com.apple.product-type.bundle.unit-test",
          "build-settings": {}
        }
      ],
      "files": [
        {
          "group": "Storefront",
          "children": [
            { "path": "StorefrontApp.swift", "target-membership": ["Storefront"] },
            {
              "group": "Checkout",
              "children": [
                { "path": "CartModel.swift", "target-membership": ["Storefront", "StorefrontTests"] },
                { "path": "PromoCodeView.swift", "target-membership": ["Storefront"] }
              ]
            }
          ]
        },
        {
          "group": "StorefrontTests",
          "children": [
            { "path": "CartModelTests.swift", "target-membership": ["StorefrontTests"] }
          ]
        }
      ],
      "package-dependencies": [
        {
          "identity": "checkout-kit",
          "url": "https://github.com/example-org/checkout-kit.git",
          "requirement": { "kind": "upToNextMajorVersion", "minimum-version": "2.4.0" }
        }
      ]
    }
    """

    /// The control case: the same feature work with none of the extras. Exists so
    /// the demo can show the gate staying quiet — a gate that always fires teaches
    /// nothing about the gate.
    public static let storefrontRoutineEdit = """
    {
      "schema-version": 1,
      "name": "Storefront",
      "build-settings": {
        "SWIFT_VERSION": "6.0",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "ENABLE_USER_SCRIPT_SANDBOXING": true,
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]": "DEBUG",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS": true
      },
      "targets": [
        {
          "name": "Storefront",
          "product-type": "com.apple.product-type.application",
          "build-settings": {
            "CODE_SIGN_IDENTITY": "Apple Development",
            "DEVELOPMENT_TEAM": "AB12CD34EF"
          },
          "package-product-dependencies": ["CheckoutKit"]
        },
        {
          "name": "StorefrontTests",
          "product-type": "com.apple.product-type.bundle.unit-test",
          "build-settings": {}
        }
      ],
      "files": [
        {
          "group": "Storefront",
          "children": [
            { "path": "StorefrontApp.swift", "target-membership": ["Storefront"] },
            {
              "group": "Checkout",
              "children": [
                { "path": "CartModel.swift", "target-membership": ["Storefront", "StorefrontTests"] },
                { "path": "PromoCodeView.swift", "target-membership": ["Storefront"] }
              ]
            }
          ]
        },
        {
          "group": "StorefrontTests",
          "children": [
            { "path": "CartModelTests.swift", "target-membership": ["StorefrontTests"] },
            { "path": "PromoCodeTests.swift", "target-membership": ["StorefrontTests"] }
          ]
        }
      ],
      "package-dependencies": [
        {
          "identity": "checkout-kit",
          "url": "https://github.com/example-org/checkout-kit.git",
          "requirement": { "kind": "upToNextMajorVersion", "minimum-version": "2.4.0" }
        }
      ]
    }
    """

    /// The supply-chain case: the dependency is re-pointed at a look-alike fork and
    /// switched to a branch, the deployment floor is lowered, and a file outside the
    /// repository is added to the app target. Every version number a skimming
    /// reviewer would check stays plausible.
    public static let storefrontSupplyChainEdit = """
    {
      "schema-version": 1,
      "name": "Storefront",
      "build-settings": {
        "SWIFT_VERSION": "6.0",
        "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
        "ENABLE_USER_SCRIPT_SANDBOXING": true,
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]": "DEBUG"
      },
      "targets": [
        {
          "name": "Storefront",
          "product-type": "com.apple.product-type.application",
          "build-settings": {
            "CODE_SIGN_IDENTITY": "Apple Development",
            "DEVELOPMENT_TEAM": "AB12CD34EF"
          },
          "package-product-dependencies": ["CheckoutKit"]
        },
        {
          "name": "StorefrontTests",
          "product-type": "com.apple.product-type.bundle.unit-test",
          "build-settings": {}
        }
      ],
      "files": [
        {
          "group": "Storefront",
          "children": [
            { "path": "StorefrontApp.swift", "target-membership": ["Storefront"] },
            { "path": "../../shared-tools/Telemetry.swift", "target-membership": ["Storefront"] },
            {
              "group": "Checkout",
              "children": [
                { "path": "CartModel.swift", "target-membership": ["Storefront", "StorefrontTests"] }
              ]
            }
          ]
        },
        {
          "group": "StorefrontTests",
          "children": [
            { "path": "CartModelTests.swift", "target-membership": ["StorefrontTests"] }
          ]
        }
      ],
      "package-dependencies": [
        {
          "identity": "checkout-kit",
          "url": "https://github.com/example-0rg/checkout-kit.git",
          "requirement": { "kind": "branch", "branch": "main" }
        }
      ]
    }
    """

    // MARK: - pbxproj

    /// The same project as `storefrontBaseline`, in the legacy format.
    ///
    /// Written to be byte-for-byte *different* and semantically *identical*: the
    /// settings are duplicated across two `XCBuildConfiguration` objects, booleans
    /// are the strings `YES`/`NO`, paths go through a group tree, and every object
    /// is addressed by a 24-character hex id. If the bridge and the hoist both work,
    /// diffing this against `storefrontBaseline` yields no structural changes —
    /// only the cross-format advisory.
    public static let storefrontLegacy = """
    // !$*UTF8*$!
    {
      archiveVersion = 1;
      classes = {};
      objectVersion = 56;
      objects = {

    /* Begin PBXBuildFile section */
        AA0000000000000000000001 /* StorefrontApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000001 /* StorefrontApp.swift */; };
        AA0000000000000000000002 /* CartModel.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000002 /* CartModel.swift */; };
        AA0000000000000000000003 /* CartModel.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000002 /* CartModel.swift */; };
        AA0000000000000000000004 /* CartModelTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000003 /* CartModelTests.swift */; };
    /* End PBXBuildFile section */

    /* Begin PBXFileReference section */
        BB0000000000000000000001 /* StorefrontApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = StorefrontApp.swift; sourceTree = "<group>"; };
        BB0000000000000000000002 /* CartModel.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CartModel.swift; sourceTree = "<group>"; };
        BB0000000000000000000003 /* CartModelTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CartModelTests.swift; sourceTree = "<group>"; };
    /* End PBXFileReference section */

    /* Begin PBXGroup section */
        CC0000000000000000000001 = {isa = PBXGroup; children = (CC0000000000000000000002, CC0000000000000000000004); sourceTree = "<group>"; };
        CC0000000000000000000002 /* Storefront */ = {isa = PBXGroup; children = (BB0000000000000000000001, CC0000000000000000000003); path = Storefront; sourceTree = "<group>"; };
        CC0000000000000000000003 /* Checkout */ = {isa = PBXGroup; children = (BB0000000000000000000002); path = Checkout; sourceTree = "<group>"; };
        CC0000000000000000000004 /* StorefrontTests */ = {isa = PBXGroup; children = (BB0000000000000000000003); path = StorefrontTests; sourceTree = "<group>"; };
    /* End PBXGroup section */

    /* Begin PBXNativeTarget section */
        DD0000000000000000000001 /* Storefront */ = {
          isa = PBXNativeTarget;
          buildConfigurationList = EE0000000000000000000002;
          buildPhases = (FF0000000000000000000001);
          name = Storefront;
          packageProductDependencies = (110000000000000000000002);
          productType = "com.apple.product-type.application";
        };
        DD0000000000000000000002 /* StorefrontTests */ = {
          isa = PBXNativeTarget;
          buildConfigurationList = EE0000000000000000000003;
          buildPhases = (FF0000000000000000000002);
          name = StorefrontTests;
          packageProductDependencies = ();
          productType = "com.apple.product-type.bundle.unit-test";
        };
    /* End PBXNativeTarget section */

    /* Begin PBXProject section */
        00E0000000000000000000FF /* Project object */ = {
          isa = PBXProject;
          buildConfigurationList = EE0000000000000000000001;
          mainGroup = CC0000000000000000000001;
          name = Storefront;
          packageReferences = (110000000000000000000001);
          targets = (DD0000000000000000000001, DD0000000000000000000002);
        };
    /* End PBXProject section */

    /* Begin PBXSourcesBuildPhase section */
        FF0000000000000000000001 /* Sources */ = {isa = PBXSourcesBuildPhase; files = (AA0000000000000000000001, AA0000000000000000000002); };
        FF0000000000000000000002 /* Sources */ = {isa = PBXSourcesBuildPhase; files = (AA0000000000000000000003, AA0000000000000000000004); };
    /* End PBXSourcesBuildPhase section */

    /* Begin XCBuildConfiguration section */
        99000000000000000000DA01 /* Debug */ = {
          isa = XCBuildConfiguration;
          buildSettings = {
            ENABLE_USER_SCRIPT_SANDBOXING = YES;
            IPHONEOS_DEPLOYMENT_TARGET = 17.0;
            SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
            SWIFT_VERSION = 6.0;
          };
          name = Debug;
        };
        99000000000000000000FA01 /* Release */ = {
          isa = XCBuildConfiguration;
          buildSettings = {
            ENABLE_USER_SCRIPT_SANDBOXING = YES;
            IPHONEOS_DEPLOYMENT_TARGET = 17.0;
            SWIFT_VERSION = 6.0;
          };
          name = Release;
        };
        99000000000000000000DA02 /* Debug */ = {
          isa = XCBuildConfiguration;
          buildSettings = {
            CODE_SIGN_IDENTITY = "Apple Development";
            DEVELOPMENT_TEAM = AB12CD34EF;
          };
          name = Debug;
        };
        99000000000000000000FA02 /* Release */ = {
          isa = XCBuildConfiguration;
          buildSettings = {
            CODE_SIGN_IDENTITY = "Apple Development";
            DEVELOPMENT_TEAM = AB12CD34EF;
          };
          name = Release;
        };
        99000000000000000000DA03 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
        99000000000000000000FA03 /* Release */ = {isa = XCBuildConfiguration; buildSettings = {}; name = Release; };
    /* End XCBuildConfiguration section */

    /* Begin XCConfigurationList section */
        EE0000000000000000000001 = {isa = XCConfigurationList; buildConfigurations = (99000000000000000000DA01, 99000000000000000000FA01); };
        EE0000000000000000000002 = {isa = XCConfigurationList; buildConfigurations = (99000000000000000000DA02, 99000000000000000000FA02); };
        EE0000000000000000000003 = {isa = XCConfigurationList; buildConfigurations = (99000000000000000000DA03, 99000000000000000000FA03); };
    /* End XCConfigurationList section */

    /* Begin XCRemoteSwiftPackageReference section */
        110000000000000000000001 /* XCRemoteSwiftPackageReference "checkout-kit" */ = {
          isa = XCRemoteSwiftPackageReference;
          repositoryURL = "https://github.com/example-org/checkout-kit.git";
          requirement = { kind = upToNextMajorVersion; minimumVersion = 2.4.0; };
        };
    /* End XCRemoteSwiftPackageReference section */

    /* Begin XCSwiftPackageProductDependency section */
        110000000000000000000002 /* CheckoutKit */ = {isa = XCSwiftPackageProductDependency; package = 110000000000000000000001; productName = CheckoutKit; };
    /* End XCSwiftPackageProductDependency section */

      };
      rootObject = 00E0000000000000000000FF /* Project object */;
    }
    """
}

extension ReviewScenario {

    /// The scenarios the demo app ships with, in the order it presents them.
    ///
    /// The first is the blocked one on purpose: the app's default state must show
    /// the product doing its job, not an empty list the reader has to go looking
    /// for a reason to populate.
    public static let samples: [ReviewScenario] = [
        ReviewScenario(
            id: "agent-edit",
            title: "Agent adds a screen — and two other things",
            detail: """
                The task was "add the promo code view." The agent did that, and also \
                disabled script sandboxing project-wide and added a Release-only \
                CODE_SIGN_IDENTITY override. The unconditioned signing key is untouched, \
                so a reviewer reading the Debug column sees nothing wrong.
                """,
            baseline: .xcproj(SampleProjects.storefrontBaseline),
            proposed: .xcproj(SampleProjects.storefrontAgentEdit)
        ),
        ReviewScenario(
            id: "supply-chain",
            title: "Dependency re-pointed, floor lowered, out-of-tree file added",
            detail: """
                The dependency now resolves from example-0rg rather than example-org and \
                tracks a branch instead of a version, the deployment floor drops to 15.0, \
                and the app target compiles a file two directories above the repository.
                """,
            baseline: .xcproj(SampleProjects.storefrontBaseline),
            proposed: .xcproj(SampleProjects.storefrontSupplyChainEdit)
        ),
        ReviewScenario(
            id: "routine",
            title: "Routine feature work",
            detail: """
                The same promo code feature with its tests, and a project-wide \
                warnings-as-errors flag. Nothing frozen moves. The gate should stay quiet — \
                a gate that fires on every commit gets disabled on the second week.
                """,
            baseline: .xcproj(SampleProjects.storefrontBaseline),
            proposed: .xcproj(SampleProjects.storefrontRoutineEdit)
        ),
        ReviewScenario(
            id: "migration",
            title: "Migration: project.pbxproj → project.xcproj",
            detail: """
                The same project in both formats. PbxprojBridge projects the legacy file \
                into the same graph and hoists settings that are uniform across \
                configurations, so the migration reads as no structural change at all \
                rather than as every setting in the file moving at once.
                """,
            baseline: .pbxproj(SampleProjects.storefrontLegacy),
            proposed: .xcproj(SampleProjects.storefrontBaseline)
        )
    ]
}
