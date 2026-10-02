import Foundation

/// Locates LapCatCore's SwiftPM resource bundle.
///
/// SwiftPM's generated `Bundle.module` looks next to the executable's bundle root
/// (`LapCat.app/LapCat_LapCatCore.bundle`, which would break the app's code seal) and then in the
/// build directory. `scripts/bundle-app.sh` copies resource bundles into `Contents/Resources/`, so
/// that location is checked first; `Bundle.module` covers `swift run` and tests.
enum LapCatCoreResources {
    static let bundleName = "LapCat_LapCatCore.bundle"

    static let bundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent(bundleName))
        {
            return bundle
        }
        return Bundle.module
    }()
}
