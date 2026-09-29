#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
PROJECT_DIR = File.join(ROOT, "ListenLater.xcodeproj")

def identifier(label)
  Digest::SHA1.hexdigest(label).upcase[0, 24]
end

def quoted(value)
  %("#{value.gsub("\\", "\\\\").gsub('"', '\\"')}")
end

def file_type(path)
  case File.extname(path)
  when ".swift" then "sourcecode.swift"
  when ".plist" then "text.plist.xml"
  when ".entitlements" then "text.plist.entitlements"
  when ".xcconfig" then "text.xcconfig"
  else
    path.end_with?(".xcassets") ? "folder.assetcatalog" : "text"
  end
end

def source_files(directory)
  Dir.glob(File.join(ROOT, directory, "**", "*.swift"))
    .map { |path| path.delete_prefix("#{ROOT}/") }
    .sort
end

app_sources = source_files("ListenLater")
core_sources = source_files("ListenLaterCore")
share_sources = source_files("ListenLaterShare")
test_sources = source_files("ListenLaterTests")

app_group_files = app_sources + [
  "ListenLater/Assets.xcassets",
  "ListenLater/Info.plist",
  "ListenLater/ListenLater.entitlements"
]
core_group_files = core_sources
share_group_files = share_sources + [
  "ListenLaterShare/Info.plist",
  "ListenLaterShare/ListenLaterShare.entitlements"
]
test_group_files = test_sources
config_group_files = [
  "Config/Base.xcconfig",
  "Config/Secrets.xcconfig.example"
]
all_file_references = (
  app_group_files + core_group_files + share_group_files +
    test_group_files + config_group_files
).uniq

project_id = identifier("project")
main_group_id = identifier("group:main")
app_group_id = identifier("group:app")
core_group_id = identifier("group:core")
share_group_id = identifier("group:share")
test_group_id = identifier("group:tests")
config_group_id = identifier("group:config")
products_group_id = identifier("group:products")

app_target_id = identifier("target:app")
share_target_id = identifier("target:share")
test_target_id = identifier("target:tests")

app_product_id = identifier("product:app")
share_product_id = identifier("product:share")
test_product_id = identifier("product:tests")

app_sources_phase = identifier("phase:app:sources")
app_frameworks_phase = identifier("phase:app:frameworks")
app_resources_phase = identifier("phase:app:resources")
app_embed_phase = identifier("phase:app:embed")
share_sources_phase = identifier("phase:share:sources")
share_frameworks_phase = identifier("phase:share:frameworks")
share_resources_phase = identifier("phase:share:resources")
test_sources_phase = identifier("phase:tests:sources")
test_frameworks_phase = identifier("phase:tests:frameworks")
test_resources_phase = identifier("phase:tests:resources")

app_config_list = identifier("config-list:app")
share_config_list = identifier("config-list:share")
test_config_list = identifier("config-list:tests")
project_config_list = identifier("config-list:project")

app_debug_config = identifier("config:app:debug")
app_release_config = identifier("config:app:release")
share_debug_config = identifier("config:share:debug")
share_release_config = identifier("config:share:release")
test_debug_config = identifier("config:tests:debug")
test_release_config = identifier("config:tests:release")
project_debug_config = identifier("config:project:debug")
project_release_config = identifier("config:project:release")

share_proxy_id = identifier("proxy:share")
app_proxy_id = identifier("proxy:app")
share_dependency_id = identifier("dependency:share")
app_dependency_id = identifier("dependency:app")

base_config_ref = identifier("file:Config/Base.xcconfig")

app_source_builds = (app_sources + core_sources).map do |path|
  [identifier("build:app:#{path}"), path]
end
share_source_builds = (
  share_sources + [
    "ListenLaterCore/Providers/ApplePodcastsLink.swift",
    "ListenLaterCore/Providers/LinkClassifier.swift",
    "ListenLaterCore/Providers/ProviderParsingSupport.swift",
    "ListenLaterCore/Providers/SocialVideoURLParser.swift",
    "ListenLaterCore/Providers/YouTubeURLParser.swift",
    "ListenLaterCore/SharedQueueInbox.swift"
  ]
).map do |path|
  [identifier("build:share:#{path}"), path]
end
test_source_builds = test_sources.map do |path|
  [identifier("build:tests:#{path}"), path]
end
asset_build_id = identifier("build:app:ListenLater/Assets.xcassets")
embed_build_id = identifier("build:embed:share")

objects = []

objects << "/* Begin PBXBuildFile section */"
(app_source_builds + share_source_builds + test_source_builds).each do |build_id, path|
  objects << "\t\t#{build_id} /* #{File.basename(path)} in Sources */ = {isa = PBXBuildFile; fileRef = #{identifier("file:#{path}")} /* #{File.basename(path)} */; };"
end
objects << "\t\t#{asset_build_id} /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = #{identifier("file:ListenLater/Assets.xcassets")} /* Assets.xcassets */; };"
objects << "\t\t#{embed_build_id} /* ListenLaterShare.appex in Embed App Extensions */ = {isa = PBXBuildFile; fileRef = #{share_product_id} /* ListenLaterShare.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };"
objects << "/* End PBXBuildFile section */"
objects << ""

objects << "/* Begin PBXContainerItemProxy section */"
objects << "\t\t#{share_proxy_id} /* PBXContainerItemProxy */ = {isa = PBXContainerItemProxy; containerPortal = #{project_id} /* Project object */; proxyType = 1; remoteGlobalIDString = #{share_target_id}; remoteInfo = ListenLaterShare; };"
objects << "\t\t#{app_proxy_id} /* PBXContainerItemProxy */ = {isa = PBXContainerItemProxy; containerPortal = #{project_id} /* Project object */; proxyType = 1; remoteGlobalIDString = #{app_target_id}; remoteInfo = ListenLater; };"
objects << "/* End PBXContainerItemProxy section */"
objects << ""

objects << "/* Begin PBXCopyFilesBuildPhase section */"
objects << "\t\t#{app_embed_phase} /* Embed App Extensions */ = {"
objects << "\t\t\tisa = PBXCopyFilesBuildPhase;"
objects << "\t\t\tbuildActionMask = 2147483647;"
objects << "\t\t\tdstPath = \"\";"
objects << "\t\t\tdstSubfolderSpec = 13;"
objects << "\t\t\tfiles = (#{embed_build_id} /* ListenLaterShare.appex in Embed App Extensions */, );"
objects << "\t\t\tname = \"Embed App Extensions\";"
objects << "\t\t\trunOnlyForDeploymentPostprocessing = 0;"
objects << "\t\t};"
objects << "/* End PBXCopyFilesBuildPhase section */"
objects << ""

objects << "/* Begin PBXFileReference section */"
all_file_references.each do |path|
  path_within_group =
    case path
    when %r{\AListenLater/} then path.delete_prefix("ListenLater/")
    when %r{\AListenLaterCore/} then path.delete_prefix("ListenLaterCore/")
    when %r{\AListenLaterShare/} then path.delete_prefix("ListenLaterShare/")
    when %r{\AListenLaterTests/} then path.delete_prefix("ListenLaterTests/")
    when %r{\AConfig/} then path.delete_prefix("Config/")
    else path
    end
  objects << "\t\t#{identifier("file:#{path}")} /* #{File.basename(path)} */ = {isa = PBXFileReference; lastKnownFileType = #{file_type(path)}; path = #{quoted(path_within_group)}; sourceTree = \"<group>\"; };"
end
objects << "\t\t#{app_product_id} /* ListenLater.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ListenLater.app; sourceTree = BUILT_PRODUCTS_DIR; };"
objects << "\t\t#{share_product_id} /* ListenLaterShare.appex */ = {isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = ListenLaterShare.appex; sourceTree = BUILT_PRODUCTS_DIR; };"
objects << "\t\t#{test_product_id} /* ListenLaterTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ListenLaterTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };"
objects << "/* End PBXFileReference section */"
objects << ""

objects << "/* Begin PBXFrameworksBuildPhase section */"
[
  [app_frameworks_phase, "Frameworks"],
  [share_frameworks_phase, "Frameworks"],
  [test_frameworks_phase, "Frameworks"]
].each do |phase_id, name|
  objects << "\t\t#{phase_id} /* #{name} */ = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };"
end
objects << "/* End PBXFrameworksBuildPhase section */"
objects << ""

def group_object(id, name, path, files)
  children = files.map do |file|
    "\t\t\t\t#{identifier("file:#{file}")} /* #{File.basename(file)} */,"
  end
  [
    "\t\t#{id} /* #{name} */ = {",
    "\t\t\tisa = PBXGroup;",
    "\t\t\tchildren = (",
    *children,
    "\t\t\t);",
    ("\t\t\tpath = #{path};" if path),
    "\t\t\tsourceTree = \"<group>\";",
    "\t\t};"
  ].compact
end

objects << "/* Begin PBXGroup section */"
objects.concat([
  "\t\t#{main_group_id} = {",
  "\t\t\tisa = PBXGroup;",
  "\t\t\tchildren = (",
  "\t\t\t\t#{app_group_id} /* ListenLater */,",
  "\t\t\t\t#{core_group_id} /* ListenLaterCore */,",
  "\t\t\t\t#{share_group_id} /* ListenLaterShare */,",
  "\t\t\t\t#{test_group_id} /* ListenLaterTests */,",
  "\t\t\t\t#{config_group_id} /* Config */,",
  "\t\t\t\t#{products_group_id} /* Products */,",
  "\t\t\t);",
  "\t\t\tsourceTree = \"<group>\";",
  "\t\t};"
])
objects.concat(group_object(app_group_id, "ListenLater", "ListenLater", app_group_files))
objects.concat(group_object(core_group_id, "ListenLaterCore", "ListenLaterCore", core_group_files))
objects.concat(group_object(share_group_id, "ListenLaterShare", "ListenLaterShare", share_group_files))
objects.concat(group_object(test_group_id, "ListenLaterTests", "ListenLaterTests", test_group_files))
objects.concat(group_object(config_group_id, "Config", "Config", config_group_files))
objects.concat([
  "\t\t#{products_group_id} /* Products */ = {",
  "\t\t\tisa = PBXGroup;",
  "\t\t\tchildren = (",
  "\t\t\t\t#{app_product_id} /* ListenLater.app */,",
  "\t\t\t\t#{share_product_id} /* ListenLaterShare.appex */,",
  "\t\t\t\t#{test_product_id} /* ListenLaterTests.xctest */,",
  "\t\t\t);",
  "\t\t\tname = Products;",
  "\t\t\tsourceTree = \"<group>\";",
  "\t\t};"
])
objects << "/* End PBXGroup section */"
objects << ""

objects << "/* Begin PBXNativeTarget section */"
objects.concat([
  "\t\t#{app_target_id} /* ListenLater */ = {",
  "\t\t\tisa = PBXNativeTarget;",
  "\t\t\tbuildConfigurationList = #{app_config_list} /* Build configuration list for PBXNativeTarget \"ListenLater\" */;",
  "\t\t\tbuildPhases = (#{app_sources_phase} /* Sources */, #{app_frameworks_phase} /* Frameworks */, #{app_resources_phase} /* Resources */, #{app_embed_phase} /* Embed App Extensions */, );",
  "\t\t\tbuildRules = ();",
  "\t\t\tdependencies = (#{share_dependency_id} /* PBXTargetDependency */, );",
  "\t\t\tname = ListenLater;",
  "\t\t\tproductName = ListenLater;",
  "\t\t\tproductReference = #{app_product_id} /* ListenLater.app */;",
  "\t\t\tproductType = \"com.apple.product-type.application\";",
  "\t\t};",
  "\t\t#{share_target_id} /* ListenLaterShare */ = {",
  "\t\t\tisa = PBXNativeTarget;",
  "\t\t\tbuildConfigurationList = #{share_config_list} /* Build configuration list for PBXNativeTarget \"ListenLaterShare\" */;",
  "\t\t\tbuildPhases = (#{share_sources_phase} /* Sources */, #{share_frameworks_phase} /* Frameworks */, #{share_resources_phase} /* Resources */, );",
  "\t\t\tbuildRules = ();",
  "\t\t\tdependencies = ();",
  "\t\t\tname = ListenLaterShare;",
  "\t\t\tproductName = ListenLaterShare;",
  "\t\t\tproductReference = #{share_product_id} /* ListenLaterShare.appex */;",
  "\t\t\tproductType = \"com.apple.product-type.app-extension\";",
  "\t\t};",
  "\t\t#{test_target_id} /* ListenLaterTests */ = {",
  "\t\t\tisa = PBXNativeTarget;",
  "\t\t\tbuildConfigurationList = #{test_config_list} /* Build configuration list for PBXNativeTarget \"ListenLaterTests\" */;",
  "\t\t\tbuildPhases = (#{test_sources_phase} /* Sources */, #{test_frameworks_phase} /* Frameworks */, #{test_resources_phase} /* Resources */, );",
  "\t\t\tbuildRules = ();",
  "\t\t\tdependencies = (#{app_dependency_id} /* PBXTargetDependency */, );",
  "\t\t\tname = ListenLaterTests;",
  "\t\t\tproductName = ListenLaterTests;",
  "\t\t\tproductReference = #{test_product_id} /* ListenLaterTests.xctest */;",
  "\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";",
  "\t\t};"
])
objects << "/* End PBXNativeTarget section */"
objects << ""

objects << "/* Begin PBXProject section */"
objects.concat([
  "\t\t#{project_id} /* Project object */ = {",
  "\t\t\tisa = PBXProject;",
  "\t\t\tattributes = {",
  "\t\t\t\tBuildIndependentTargetsInParallel = 1;",
  "\t\t\t\tLastSwiftUpdateCheck = 2660;",
  "\t\t\t\tLastUpgradeCheck = 2660;",
  "\t\t\t\tTargetAttributes = {",
  "\t\t\t\t\t#{app_target_id} = {CreatedOnToolsVersion = 26.6; };",
  "\t\t\t\t\t#{share_target_id} = {CreatedOnToolsVersion = 26.6; };",
  "\t\t\t\t\t#{test_target_id} = {CreatedOnToolsVersion = 26.6; TestTargetID = #{app_target_id}; };",
  "\t\t\t\t};",
  "\t\t\t};",
  "\t\t\tbuildConfigurationList = #{project_config_list} /* Build configuration list for PBXProject \"ListenLater\" */;",
  "\t\t\tcompatibilityVersion = \"Xcode 14.0\";",
  "\t\t\tdevelopmentRegion = en;",
  "\t\t\thasScannedForEncodings = 0;",
  "\t\t\tknownRegions = (en, Base, );",
  "\t\t\tmainGroup = #{main_group_id};",
  "\t\t\tproductRefGroup = #{products_group_id} /* Products */;",
  "\t\t\tprojectDirPath = \"\";",
  "\t\t\tprojectRoot = \"\";",
  "\t\t\ttargets = (#{app_target_id} /* ListenLater */, #{share_target_id} /* ListenLaterShare */, #{test_target_id} /* ListenLaterTests */, );",
  "\t\t};"
])
objects << "/* End PBXProject section */"
objects << ""

objects << "/* Begin PBXResourcesBuildPhase section */"
objects << "\t\t#{app_resources_phase} /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (#{asset_build_id} /* Assets.xcassets in Resources */, ); runOnlyForDeploymentPostprocessing = 0; };"
objects << "\t\t#{share_resources_phase} /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };"
objects << "\t\t#{test_resources_phase} /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };"
objects << "/* End PBXResourcesBuildPhase section */"
objects << ""

def sources_phase(id, builds)
  files = builds.map do |build_id, path|
    "\t\t\t\t#{build_id} /* #{File.basename(path)} in Sources */,"
  end
  [
    "\t\t#{id} /* Sources */ = {",
    "\t\t\tisa = PBXSourcesBuildPhase;",
    "\t\t\tbuildActionMask = 2147483647;",
    "\t\t\tfiles = (",
    *files,
    "\t\t\t);",
    "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
    "\t\t};"
  ]
end

objects << "/* Begin PBXSourcesBuildPhase section */"
objects.concat(sources_phase(app_sources_phase, app_source_builds))
objects.concat(sources_phase(share_sources_phase, share_source_builds))
objects.concat(sources_phase(test_sources_phase, test_source_builds))
objects << "/* End PBXSourcesBuildPhase section */"
objects << ""

objects << "/* Begin PBXTargetDependency section */"
objects << "\t\t#{share_dependency_id} /* PBXTargetDependency */ = {isa = PBXTargetDependency; target = #{share_target_id} /* ListenLaterShare */; targetProxy = #{share_proxy_id} /* PBXContainerItemProxy */; };"
objects << "\t\t#{app_dependency_id} /* PBXTargetDependency */ = {isa = PBXTargetDependency; target = #{app_target_id} /* ListenLater */; targetProxy = #{app_proxy_id} /* PBXContainerItemProxy */; };"
objects << "/* End PBXTargetDependency section */"
objects << ""

def settings_block(values)
  values.map do |key, value|
    rendered =
      case value
      when Array
        "(#{value.map { |item| quoted(item.to_s) }.join(", ")}, )"
      when Integer
        value.to_s
      else
        quoted(value.to_s)
      end
    "\t\t\t\t#{key} = #{rendered};"
  end
end

common_project_settings = {
  "ALWAYS_SEARCH_USER_PATHS" => "NO",
  "CLANG_ANALYZER_NONNULL" => "YES",
  "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION" => "YES_AGGRESSIVE",
  "CLANG_CXX_LANGUAGE_STANDARD" => "gnu++20",
  "CLANG_ENABLE_MODULES" => "YES",
  "CLANG_ENABLE_OBJC_ARC" => "YES",
  "CLANG_ENABLE_OBJC_WEAK" => "YES",
  "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING" => "YES",
  "CLANG_WARN_BOOL_CONVERSION" => "YES",
  "CLANG_WARN_COMMA" => "YES",
  "CLANG_WARN_CONSTANT_CONVERSION" => "YES",
  "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS" => "YES",
  "CLANG_WARN_DIRECT_OBJC_ISA_USAGE" => "YES_ERROR",
  "CLANG_WARN_DOCUMENTATION_COMMENTS" => "YES",
  "CLANG_WARN_EMPTY_BODY" => "YES",
  "CLANG_WARN_ENUM_CONVERSION" => "YES",
  "CLANG_WARN_INFINITE_RECURSION" => "YES",
  "CLANG_WARN_INT_CONVERSION" => "YES",
  "CLANG_WARN_NON_LITERAL_NULL_CONVERSION" => "YES",
  "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF" => "YES",
  "CLANG_WARN_OBJC_LITERAL_CONVERSION" => "YES",
  "CLANG_WARN_OBJC_ROOT_CLASS" => "YES_ERROR",
  "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER" => "YES",
  "CLANG_WARN_RANGE_LOOP_ANALYSIS" => "YES",
  "CLANG_WARN_STRICT_PROTOTYPES" => "YES",
  "CLANG_WARN_SUSPICIOUS_MOVE" => "YES",
  "CLANG_WARN_UNGUARDED_AVAILABILITY" => "YES_AGGRESSIVE",
  "CLANG_WARN_UNREACHABLE_CODE" => "YES",
  "CLANG_WARN__DUPLICATE_METHOD_MATCH" => "YES",
  "COPY_PHASE_STRIP" => "NO",
  "ENABLE_STRICT_OBJC_MSGSEND" => "YES",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "GCC_C_LANGUAGE_STANDARD" => "gnu17",
  "GCC_NO_COMMON_BLOCKS" => "YES",
  "GCC_WARN_64_TO_32_BIT_CONVERSION" => "YES",
  "GCC_WARN_ABOUT_RETURN_TYPE" => "YES_ERROR",
  "GCC_WARN_UNDECLARED_SELECTOR" => "YES",
  "GCC_WARN_UNINITIALIZED_AUTOS" => "YES_AGGRESSIVE",
  "GCC_WARN_UNUSED_FUNCTION" => "YES",
  "GCC_WARN_UNUSED_VARIABLE" => "YES",
  "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
  "LOCALIZATION_PREFERS_STRING_CATALOGS" => "YES",
  "SDKROOT" => "iphoneos",
  "SWIFT_VERSION" => "5.0"
}

app_settings = {
  "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
  "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME" => "AccentColor",
  "CODE_SIGN_ENTITLEMENTS" => "ListenLater/ListenLater.entitlements",
  "CODE_SIGN_STYLE" => "Automatic",
  "CURRENT_PROJECT_VERSION" => "1",
  "ENABLE_PREVIEWS" => "YES",
  "GENERATE_INFOPLIST_FILE" => "NO",
  "INFOPLIST_FILE" => "ListenLater/Info.plist",
  "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/Frameworks"],
  "MARKETING_VERSION" => "1.0",
  "PRODUCT_BUNDLE_IDENTIFIER" => "com.kevinthau.ListenLater",
  "PRODUCT_NAME" => "$(TARGET_NAME)",
  "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator",
  "SWIFT_EMIT_LOC_STRINGS" => "YES",
  "SWIFT_STRICT_CONCURRENCY" => "targeted",
  "TARGETED_DEVICE_FAMILY" => "1,2"
}

share_settings = {
  "APPLICATION_EXTENSION_API_ONLY" => "YES",
  "CODE_SIGN_ENTITLEMENTS" => "ListenLaterShare/ListenLaterShare.entitlements",
  "CODE_SIGN_STYLE" => "Automatic",
  "CURRENT_PROJECT_VERSION" => "1",
  "GENERATE_INFOPLIST_FILE" => "NO",
  "INFOPLIST_FILE" => "ListenLaterShare/Info.plist",
  "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/../../Frameworks"],
  "MARKETING_VERSION" => "1.0",
  "PRODUCT_BUNDLE_IDENTIFIER" => "com.kevinthau.ListenLater.AddToQueue",
  "PRODUCT_NAME" => "$(TARGET_NAME)",
  "SKIP_INSTALL" => "YES",
  "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator",
  "SWIFT_EMIT_LOC_STRINGS" => "YES",
  "SWIFT_STRICT_CONCURRENCY" => "targeted",
  "TARGETED_DEVICE_FAMILY" => "1,2"
}

test_settings = {
  "BUNDLE_LOADER" => "$(TEST_HOST)",
  "CODE_SIGN_STYLE" => "Automatic",
  "CURRENT_PROJECT_VERSION" => "1",
  "GENERATE_INFOPLIST_FILE" => "YES",
  "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
  "MARKETING_VERSION" => "1.0",
  "PRODUCT_BUNDLE_IDENTIFIER" => "com.kevinthau.ListenLaterTests",
  "PRODUCT_NAME" => "$(TARGET_NAME)",
  "SUPPORTED_PLATFORMS" => "iphoneos iphonesimulator",
  "SWIFT_STRICT_CONCURRENCY" => "targeted",
  "TARGETED_DEVICE_FAMILY" => "1,2",
  "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/ListenLater.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/ListenLater"
}

configurations = [
  [project_debug_config, "Debug", common_project_settings.merge(
    "DEBUG_INFORMATION_FORMAT" => "dwarf",
    "ENABLE_TESTABILITY" => "YES",
    "GCC_OPTIMIZATION_LEVEL" => "0",
    "GCC_PREPROCESSOR_DEFINITIONS" => ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO" => "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH" => "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS" => "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL" => "-Onone"
  )],
  [project_release_config, "Release", common_project_settings.merge(
    "DEBUG_INFORMATION_FORMAT" => "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS" => "NO",
    "MTL_ENABLE_DEBUG_INFO" => "NO",
    "SWIFT_COMPILATION_MODE" => "wholemodule",
    "VALIDATE_PRODUCT" => "YES"
  )],
  [app_debug_config, "Debug", app_settings],
  [app_release_config, "Release", app_settings],
  [share_debug_config, "Debug", share_settings],
  [share_release_config, "Release", share_settings],
  [test_debug_config, "Debug", test_settings],
  [test_release_config, "Release", test_settings]
]

objects << "/* Begin XCBuildConfiguration section */"
configurations.each do |config_id, name, settings|
  objects << "\t\t#{config_id} /* #{name} */ = {"
  objects << "\t\t\tisa = XCBuildConfiguration;"
  objects << "\t\t\tbaseConfigurationReference = #{base_config_ref} /* Base.xcconfig */;"
  objects << "\t\t\tbuildSettings = {"
  objects.concat(settings_block(settings))
  objects << "\t\t\t};"
  objects << "\t\t\tname = #{name};"
  objects << "\t\t};"
end
objects << "/* End XCBuildConfiguration section */"
objects << ""

objects << "/* Begin XCConfigurationList section */"
[
  [project_config_list, "PBXProject \"ListenLater\"", project_debug_config, project_release_config],
  [app_config_list, "PBXNativeTarget \"ListenLater\"", app_debug_config, app_release_config],
  [share_config_list, "PBXNativeTarget \"ListenLaterShare\"", share_debug_config, share_release_config],
  [test_config_list, "PBXNativeTarget \"ListenLaterTests\"", test_debug_config, test_release_config]
].each do |list_id, comment, debug_id, release_id|
  objects << "\t\t#{list_id} /* Build configuration list for #{comment} */ = {isa = XCConfigurationList; buildConfigurations = (#{debug_id} /* Debug */, #{release_id} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };"
end
objects << "/* End XCConfigurationList section */"

project = <<~PBX
  // !$*UTF8*$!
  {
  \tarchiveVersion = 1;
  \tclasses = {
  \t};
  \tobjectVersion = 56;
  \tobjects = {

  #{objects.join("\n")}
  \t};
  \trootObject = #{project_id} /* Project object */;
  }
PBX

scheme = <<~XML
  <?xml version="1.0" encoding="UTF-8"?>
  <Scheme LastUpgradeVersion = "2660" version = "1.7">
     <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
        <BuildActionEntries>
           <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
              <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{app_target_id}" BuildableName = "ListenLater.app" BlueprintName = "ListenLater" ReferencedContainer = "container:ListenLater.xcodeproj"/>
           </BuildActionEntry>
           <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "NO">
              <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{test_target_id}" BuildableName = "ListenLaterTests.xctest" BlueprintName = "ListenLaterTests" ReferencedContainer = "container:ListenLater.xcodeproj"/>
           </BuildActionEntry>
        </BuildActionEntries>
     </BuildAction>
     <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
        <Testables>
           <TestableReference skipped = "NO">
              <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{test_target_id}" BuildableName = "ListenLaterTests.xctest" BlueprintName = "ListenLaterTests" ReferencedContainer = "container:ListenLater.xcodeproj"/>
           </TestableReference>
        </Testables>
     </TestAction>
     <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
        <BuildableProductRunnable runnableDebuggingMode = "0">
           <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{app_target_id}" BuildableName = "ListenLater.app" BlueprintName = "ListenLater" ReferencedContainer = "container:ListenLater.xcodeproj"/>
        </BuildableProductRunnable>
     </LaunchAction>
     <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
        <BuildableProductRunnable runnableDebuggingMode = "0">
           <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{app_target_id}" BuildableName = "ListenLater.app" BlueprintName = "ListenLater" ReferencedContainer = "container:ListenLater.xcodeproj"/>
        </BuildableProductRunnable>
     </ProfileAction>
     <AnalyzeAction buildConfiguration = "Debug"/>
     <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
  </Scheme>
XML

FileUtils.mkdir_p(File.join(PROJECT_DIR, "xcshareddata", "xcschemes"))
File.write(File.join(PROJECT_DIR, "project.pbxproj"), project)
File.write(
  File.join(PROJECT_DIR, "xcshareddata", "xcschemes", "ListenLater.xcscheme"),
  scheme
)

puts "Generated #{File.join(PROJECT_DIR, 'project.pbxproj')}"
puts "App sources: #{app_source_builds.count}; share sources: #{share_source_builds.count}; tests: #{test_source_builds.count}"
