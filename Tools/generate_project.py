#!/usr/bin/env python3
"""Generate a dependency-free Xcode project for the native iPad/Catalyst app."""
import pathlib, hashlib, json, os, re
root = pathlib.Path(__file__).resolve().parents[1]
project = root / 'TDSCarKit.xcodeproj'; project.mkdir(exist_ok=True)
previous = (project / 'project.pbxproj').read_text() if (project / 'project.pbxproj').exists() else ''
def existing_setting(name, fallback):
    match = re.search(r'\b' + re.escape(name) + r'\s*=\s*"?([^";]+)"?\s*;', previous)
    return match.group(1).strip() if match else fallback
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
objects = []
def add(key, value): objects.append(f'{uid(key)} = {{ {value} }};'); return uid(key)
sources = sorted([*root.glob('App/*.swift'), *root.glob('App/*.m'), *root.rglob('Sources/TDSCarKitCore/**/*.swift'), *root.glob('Sources/CTDSCarKitCrypto/*.c')])
refs = []; builds = []
for path in sources:
    relative = str(path.relative_to(root))
    filetype = {'.c':'sourcecode.c.c', '.m':'sourcecode.c.objc', '.swift':'sourcecode.swift'}[path.suffix]
    ref = add('ref:'+relative, f'isa = PBXFileReference; lastKnownFileType = {filetype}; path = {q(relative)}; sourceTree = "<group>";')
    refs.append(ref)
    builds.append(add('build:'+relative, f'isa = PBXBuildFile; fileRef = {ref};'))
product = add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = TDSCarKit.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = add('products', f'isa = PBXGroup; name = Products; children = ({product},); sourceTree = "<group>";')
add('group', f'isa = PBXGroup; children = ({",".join(refs + [products])},); sourceTree = "<group>";')
add('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
add('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
identity_script = '''set -eu
identity_dir="${TDS_IDENTITY_DIR:-}"
if [ -z "$identity_dir" ]; then
  for candidate in "$SRCROOT/.local/Identity" "$SRCROOT/../../NativeCarCast/.local/Identity"; do
    if [ -f "$candidate/certificate.p7b" ] && [ -f "$candidate/leaf.cer" ] && [ -f "$candidate/private.x963" ]; then identity_dir="$candidate"; break; fi
  done
fi
if [ -n "$identity_dir" ]; then
  destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Identity"
  mkdir -p "$destination"
  for name in certificate.p7b leaf.cer private.x963; do
    test -f "$identity_dir/$name"
    cp "$identity_dir/$name" "$destination/$name"
  done
fi'''
add('identity-script', f'isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = {q(identity_script)}; name = "Bundle local identity";')
add('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
common = {
'PRODUCT_NAME':'TDSCarKit', 'PRODUCT_BUNDLE_IDENTIFIER':os.environ.get('TDS_BUNDLE_ID', existing_setting('PRODUCT_BUNDLE_IDENTIFIER', 'local.tds.carkit')), 'SWIFT_VERSION':'5.0',
'IPHONEOS_DEPLOYMENT_TARGET':'16.4', 'MACOSX_DEPLOYMENT_TARGET':'13.3', 'TARGETED_DEVICE_FAMILY':'1,2',
'SDKROOT':'iphoneos','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator macosx', 'SUPPORTS_MACCATALYST':'YES',
'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'YES', 'DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER':'NO',
'INFOPLIST_FILE':'App/Info.plist', 'GENERATE_INFOPLIST_FILE':'NO', 'CODE_SIGN_STYLE':'Automatic', 'CODE_SIGN_ENTITLEMENTS':'$(TDS_WIFI_ENTITLEMENTS)', 'TDS_WIFI_NAME_DETECTION':'NO',
'SWIFT_OBJC_BRIDGING_HEADER':'App/TDSCarKit-Bridging-Header.h',
'HEADER_SEARCH_PATHS':'$(SRCROOT)/Sources/CTDSCarKitCrypto/include', 'CLANG_ENABLE_MODULES':'YES',
'CLANG_ENABLE_OBJC_ARC':'YES',
'ENABLE_DEBUG_DYLIB':'NO', 'ENABLE_USER_SCRIPT_SANDBOXING':'NO', 'ENABLE_APP_SANDBOX':'NO',
'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks',
}
team = os.environ.get('TDS_TEAM_ID', existing_setting('DEVELOPMENT_TEAM', ''))
if team: common['DEVELOPMENT_TEAM'] = team
for scope in ['project','target']:
    configs=[]
    for name in ['Debug','Release']:
        settings = dict(common) if scope=='target' else {'CLANG_ENABLE_MODULES':'YES'}
        if scope=='target': settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-O','DEBUG_INFORMATION_FORMAT':'dwarf','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if name=='Debug' else ''})
        configs.append(add(scope+name, 'isa = XCBuildConfiguration; name = '+name+'; buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+'};'))
    add(scope+'configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('target',f'isa = PBXNativeTarget; name = TDSCarKit; productName = TDSCarKit; productReference = {product}; productType = "com.apple.product-type.application"; buildConfigurationList = {uid("targetconfigs")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")},{uid("identity-script")},); buildRules = (); dependencies = ();')
add('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {uid("group")}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")},);')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {uid("project")}; }}\n')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
reference=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="TDSCarKit.app" BlueprintName="TDSCarKit" ReferencedContainer="container:TDSCarKit.xcodeproj"/>'
(schemes/'TDSCarKit.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
