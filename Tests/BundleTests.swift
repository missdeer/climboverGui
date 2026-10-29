import Foundation

func testBundledTools() {
    let helper = URL(fileURLWithPath: "/Applications/App With Spaces.app/Contents/Helpers/ProxyControl")
    let root = URL(fileURLWithPath: "/tmp/project")
    require(BundledTools.executable("sslocal", helper: helper).path == "/Applications/App With Spaces.app/Contents/Helpers/sslocal", "Proxy must resolve relative to the installed helper")
    require(BundledTools.executable("coredns", helper: helper).deletingLastPathComponent() == helper.deletingLastPathComponent(), "Both engines must be bundled alongside the helper")
    for plugin in ["obfs-local", "./obfs-local", "/Users/old/path/obfs-local", "/Applications/Previous.app/Contents/Helpers/obfs-local"] {
        require(BundledTools.plugin(plugin, root: root, helper: helper) == BundledTools.executable("obfs-local", helper: helper), "Old/plugin snapshot paths must resolve to this bundle")
    }
    require(BundledTools.plugin("custom-plugin", root: root, helper: helper).path == "/tmp/project/custom-plugin", "Custom relative plugins must retain their configured behavior")
    require(BundledTools.plugin("/usr/local/bin/custom-plugin", root: root, helper: helper).path == "/usr/local/bin/custom-plugin", "Custom absolute plugins must remain intact")
    print("PASS: bundled proxy/DNS/plugin locations, relocated app, old plugin paths and custom plugins")
}
