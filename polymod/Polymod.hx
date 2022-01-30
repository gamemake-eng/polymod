/**
 * Copyright (c) 2018 Level Up Labs, LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 */

package polymod;

import polymod.fs.IFileSystem;
import haxe.Json;
import haxe.io.Bytes;
import polymod.util.SemanticVersion;
import polymod.util.SemanticVersion.SemanticVersionScore;
import polymod.util.Util;
import polymod.format.JsonHelp;
import polymod.format.ParseRules;
import polymod.backends.IBackend;
import polymod.backends.PolymodAssets;
import polymod.backends.PolymodAssetLibrary;
import polymod.backends.PolymodAssets.PolymodAssetType;
#if firetongue
import firetongue.FireTongue;
#end

typedef PolymodParams =
{
	/**
	 * root directory of all mods
	 */
	modRoot:String,

	/**
	 * directory names of one or more mods, relative to modRoot
	 */
	dirs:Array<String>,

	/**
	 * (optional) the Haxe framework you're using (OpenFL, HEAPS, Kha, NME, etc..). If not provided, Polymod will attempt to determine this automatically
	 */
	?framework:Framework,
	/**
	 * (optional) any specific settings for your particular Framework
	 */
	?frameworkParams:FrameworkParams,
	/**
	 * (optional) semantic version of your game's Modding API (will generate errors & warnings)
	 */
	?apiVersion:String,
	/**
	 * (optional) callback for any errors generated during mod initialization
	 */
	?errorCallback:PolymodError->Void,
	/**
	 * (optional) for each mod you're loading, a corresponding semantic version pattern to enforce (will generate errors & warnings)
	 * if not provided, no version checks will be made
	 */
	?modVersions:Array<String>,
	/**
	 * (optional) parsing rules for various data formats
	 */
	?parseRules:ParseRules,
	/**
	 * (optional) list of filenames to ignore in mods
	 */
	?ignoredFiles:Array<String>,
	/**
	 * (optional) your own custom backend for handling assets
	 */
	?customBackend:Class<IBackend>,
	/**
	 * (optional) a map that tells Polymod which assets are of which type. This ensures e.g. text files with unfamiliar extensions are handled properly.
	 */
	?extensionMap:Map<String, PolymodAssetType>,
	/**
	 * (optional) your own custom backend for accessing the file system
	 */
	?customFilesystem:Class<IFileSystem>,

	/**
	 * (optional) a FireTongue instance for Polymod to hook into for localization support
	 */
	#if firetongue
	?firetongue:FireTongue,
	#end
}

/**
 * Any framework-specific settings
 * Right now this is only used to specify asset library paths for the Lime/OpenFL framework but we'll add more framework-specific settings here as neeeded
 */
typedef FrameworkParams =
{
	/**
	 * (optional) if you're using Lime/OpenFL AND you're using custom or non-default asset libraries, then you must provide a key=>value store mapping the name of each asset library to a path prefix in your mod structure
	 */
	?assetLibraryPaths:Map<String, String>
}

enum Framework
{
	CASTLE;
	NME;
	LIME;
	OPENFL;
	OPENFL_WITH_NODE;
	FLIXEL;
	HEAPS;
	KHA;
	CUSTOM;
	UNKNOWN;
}

/**
 * ...
 * @author
 */
class Polymod
{
	public static var onError:PolymodError->Void = null;

	private static var assetLibrary:PolymodAssetLibrary = null;
	#if firetongue
	private static var tongue:FireTongue = null;
	#end

	/**
	 * Initializes the chosen mod or mods.
	 * @param	params initialization parameters
	 * @return	an array of metadata entries for successfully loaded mods
	 */
	public static function init(params:PolymodParams):Array<ModMetadata>
	{
		onError = params.errorCallback;

		var modRoot = params.modRoot;
		var dirs = params.dirs;
		var apiVersion:SemanticVersion = null;
		try
		{
			var apiStr = params.apiVersion;
			if (apiStr == null || apiStr == '')
			{
				apiStr = '*.*.*';
			}
			apiVersion = SemanticVersion.fromString(apiStr);
		}
		catch (msg:Dynamic)
		{
			error(PARSE_API_VERSION, 'Error parsing API version: (${msg})', INIT);
			return [];
		}

		var modMeta = [];
		var modVers = [];
		var fileSystem = if (params.customFilesystem != null)
		{
			Type.createInstance(params.customFilesystem, []);
		}
		else
		{
			#if sys
			new polymod.fs.SysFileSystem(params.modRoot);
			#elseif nodefs
			new polymod.fs.NodeFileSystem(params.modRoot);
			#else
			new polymod.fs.StubFileSystem();
			#end
		}

		if (params.modVersions != null)
		{
			for (str in params.modVersions)
			{
				var semVer = null;
				try
				{
					semVer = SemanticVersion.fromString(str);
				}
				catch (msg:Dynamic)
				{
					error(PARAM_MOD_VERSION, 'There was an error with one of the mod version patterns you provided: (${msg})', INIT);
					semVer = SemanticVersion.fromString('*.*.*');
				}
				modVers.push(semVer);
			}
		}

		for (i in 0...dirs.length)
		{
			if (dirs[i] != null)
			{
				var origDir = dirs[i];
				dirs[i] = Util.pathJoin(modRoot, dirs[i]);
				var meta:ModMetadata = fileSystem.getMetadata(dirs[i]);

				if (meta != null)
				{
					meta.id = origDir;
					var apiScore = meta.apiVersion.checkCompatibility(apiVersion);
					if (apiScore < PolymodConfig.apiVersionMatch)
					{
						error(VERSION_CONFLICT_API,
							'Mod "$origDir" was built for incompatible API version ${meta.apiVersion.toString()}, current API version is "${params.apiVersion.toString()}"',
							INIT);
					}
					else
					{
						if (apiVersion.major == 0)
						{
							// if we're in pre-release
							if (apiVersion.minor != meta.apiVersion.minor)
							{
								Polymod.warning(VERSION_PRERELEASE_API,
									'Modding API is in pre-release, some things might have changed!\n' +
									'Mod "$origDir" was built for API version ${meta.apiVersion.toString()}, current API version is "${params.apiVersion.toString()}"',
									INIT);
							}
						}
					}
					var modVer = modVers.length > i ? modVers[i] : null;
					if (modVer != null)
					{
						var score = modVer.checkCompatibility(meta.modVersion);
						if (score < SemanticVersionScore.MATCH_PATCH)
						{
							Polymod.error(VERSION_CONFLICT_MOD,
								'Mod pack wants version "${modVer.toString()}" of mod "${meta.id}", found incompatibile version ${meta.modVersion.toString()}" instead.',
								INIT);
						}
					}
					modMeta.push(meta);
				}
			}
		}

		assetLibrary = PolymodAssets.init({
			framework: params.framework,
			dirs: dirs,
			parseRules: params.parseRules,
			ignoredFiles: params.ignoredFiles,
			customBackend: params.customBackend,
			extensionMap: params.extensionMap,
			frameworkParams: params.frameworkParams,
			fileSystem: fileSystem,
			#if firetongue
			firetongue: params.firetongue,
			#end
		});

		if (assetLibrary == null)
		{
			//
			return null;
		}

		if (PolymodAssets.exists((PolymodConfig.modPackFile)))
		{
			Polymod.warning(FUNCTIONALITY_DEPRECATED, 'The pack.txt modpack format has been deprecated', INIT);
		}

		return modMeta;
	}

	public static function getDefaultIgnoreList():Array<String>
	{
		return PolymodConfig.modIgnoreFiles.concat([PolymodConfig.modMetadataFile, PolymodConfig.modIconFile,]);
	}

	/**
	 * Scan the given directory for available mods and returns their metadata entries
	 * @param modRoot root directory of all mods
	 * @param apiVersionStr (optional) enforce a modding API version -- incompatible mods will not be returned
	 * @param errorCallback (optional) callback for any errors generated during scanning
	 * @return Array<ModMetadata>
	 */
	public static function scan(modRoot:String, ?apiVersionStr:String = "*.*.*", ?errorCallback:PolymodError->Void, ?fileSystem:IFileSystem):Array<ModMetadata>
	{
		onError = errorCallback;
		var apiVersion:SemanticVersion = null;
		try
		{
			apiVersion = SemanticVersion.fromString(apiVersionStr);
		}
		catch (msg:Dynamic)
		{
			Polymod.error('Error parsing provided API version (${msg})', SCAN);
			return [];
		}

		if (fileSystem == null)
		{
			#if sys
			fileSystem = new polymod.fs.SysFileSystem(modRoot);
			#elseif nodefs
			fileSystem = new polymod.fs.NodeFileSystem(modRoot);
			#else
			fileSystem = new polymod.fs.StubFileSystem();
			#end
		}

		var modMeta = [];

		if (!fileSystem.exists(modRoot) || !fileSystem.isDirectory(modRoot))
		{
			return modMeta;
		}
		var dirs = fileSystem.readDirectory(modRoot);
		Polymod.debug('scan found ' + dirs.length + ' folders in ' + modRoot);

		// Filter to only directories.
		var l = dirs.length;
		for (i in 0...l)
		{
			var j = l - i - 1;
			var dir = dirs[j];
			var testDir = '$modRoot/$dir';
			if (!fileSystem.isDirectory(testDir) || !fileSystem.exists(testDir))
			{
				dirs.splice(j, 1);
			}
		}

		for (i in 0...dirs.length)
		{
			if (dirs[i] != null)
			{
				var origDir = dirs[i];
				dirs[i] = '$modRoot/${dirs[i]}';
				var meta:ModMetadata = fileSystem.getMetadata(dirs[i]);

				if (meta != null)
				{
					meta.id = origDir;
					var apiScore = meta.apiVersion.checkCompatibility(apiVersion);
					if (apiScore < PolymodConfig.apiVersionMatch)
					{
						Polymod.error(VERSION_CONFLICT_API,
							'Mod "$origDir" was built for incompatible API version ${meta.apiVersion)}, current version is "${apiVersion}"', SCAN);
					}
					else
					{
						if (apiVersion.major == 0)
						{
							// if we're in pre-release
							if (apiVersion.minor != meta.apiVersion.minor)
							{
								Polymod.warning(VERSION_PRERELEASE_API,
									"Modding API is in pre-release, some things might have changed!\n" +
									'Mod "$origDir" was built for incompatible API version ${meta.apiVersion)}, current version is "${apiVersion}"',
									SCAN);
							}
						}
					}
					modMeta.push(meta);
				}
			}
		}

		return modMeta;
	}

	/**
	 * Tells Polymod to force the current backend to clear any asset caches
	 */
	public static function clearCache()
	{
		if (assetLibrary != null)
		{
			Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot clear cache.');
			return;
		}

		assetLibrary.clearCache();
	}

	public static function error(code:PolymodErrorCode, message:String, origin:PolymodErrorOrigin = UNKNOWN)
	{
		if (onError != null)
		{
			onError(new PolymodError(PolymodErrorType.ERROR, code, message, origin));
		}
	}

	public static function warning(code:PolymodErrorCode, message:String, origin:PolymodErrorOrigin = UNKNOWN)
	{
		if (onError != null)
		{
			onError(new PolymodError(PolymodErrorType.WARNING, code, message, origin));
		}
	}

	public static function notice(code:PolymodErrorCode, message:String, origin:PolymodErrorOrigin = UNKNOWN)
	{
		if (onError != null)
		{
			onError(new PolymodError(PolymodErrorType.NOTICE, code, message, origin));
		}
	}

	public static function debug(message:String, ?posInfo:haxe.PosInfos):Void
	{
		#if POLYMOD_DEBUG
		if (posInfo != null)
			trace('[POLYMOD] (${posInfo.fileName}#${posInfo.lineNumber}): $message');
		else
			trace('[POLYMOD] $message');
		#end
	}

	/**
	 * Provide a list of assets included in or modified by the mod(s)
	 * @param type the type of asset you want (lime.utils.PolymodAssetType)
	 * @return Array<String> a list of assets of the matching type
	 */
	public static function listModFiles(type:PolymodAssetType = null):Array<String>
	{
		if (assetLibrary != null)
		{
			return assetLibrary.listModFiles(type);
		}

		Polymod.warning(POLYMOD_NOT_LOADED, 'Polymod is not loaded yet, cannot list files.');
		return [];
	}

	/***PRIVATE***/
}

typedef ModContributor =
{
	name:String,
	role:String,
	email:String,
	url:String
};

class ModMetadata
{
	public var id:String;
	public var title:String;
	public var description:String;
	public var homepage:String;
	public var apiVersion:SemanticVersion;
	public var modVersion:SemanticVersion;
	public var license:String;
	public var licenseRef:String;
	public var icon:Bytes;
	public var metaData:Map<String, String>;

	/**
	 * Please use the `contributors` field instead.
	 */
	@:deprecated
	public var author(get, set):String;

	// author has been made a property so setting it internally doesn't throw deprecation warnings
	var _author:String;

	function get_author()
	{
		if (contributors.length > 0)
		{
			return contributors[0].name;
		}
		return _author;
	}

	function set_author(v):String
	{
		_author = v;
		return v;
	}

	public var contributors:Array<ModContributor>;

	public function new()
	{
	}

	public function toJsonStr():String
	{
		var json = {};
		Reflect.setField(json, 'title', title);
		Reflect.setField(json, 'description', description);
		Reflect.setField(json, 'author', _author);
		Reflect.setField(json, 'contributors', contributors);
		Reflect.setField(json, 'homepage', homepage);
		Reflect.setField(json, 'api_version', apiVersion.toString());
		Reflect.setField(json, 'mod_version', modVersion.toString());
		Reflect.setField(json, 'license', license);
		Reflect.setField(json, 'license_ref', licenseRef);
		var meta = {};
		for (key in metaData.keys())
		{
			Reflect.setField(meta, key, metaData.get(key));
		}
		Reflect.setField(json, 'metadata', meta);
		return Json.stringify(json, null, '    ');
	}

	public static function fromJsonStr(str:String)
	{
		if (str == null || str == '')
		{
			Polymod.error(PARSE_MOD_META, 'Error parsing mod metadata file, was null or empty.');
			return null;
		}

		var json = null;
		try
		{
			json = haxe.Json.parse(str);
		}
		catch (msg:Dynamic)
		{
			Polymod.error(PARSE_MOD_META, 'Error parsing mod metadata file: (${msg})');
			return null;
		}

		var m = new ModMetadata();
		m.title = JsonHelp.str(json, 'title');
		m.description = JsonHelp.str(json, 'description');
		m._author = JsonHelp.str(json, 'author');
		m.contributors = JsonHelp.arrType(json, 'contributors');
		m.homepage = JsonHelp.str(json, 'homepage');
		var apiVersionStr = JsonHelp.str(json, 'api_version');
		var modVersionStr = JsonHelp.str(json, 'mod_version');
		try
		{
			m.apiVersion = SemanticVersion.fromString(apiVersionStr);
		}
		catch (msg:Dynamic)
		{
			Polymod.error(PARSE_MOD_API_VERSION, 'Error parsing API version: (${msg}) ${PolymodConfig.modMetadataFile} was ${str}');
			return null;
		}
		try
		{
			m.modVersion = SemanticVersion.fromString(modVersionStr);
		}
		catch (msg:Dynamic)
		{
			Polymod.error(PARSE_MOD_VERSION, 'Error parsing mod version: (${msg}) ${PolymodConfig.modMetadataFile} was ${str}');
			return null;
		}
		m.license = JsonHelp.str(json, 'license');
		m.licenseRef = JsonHelp.str(json, 'license_ref');
		m.metaData = JsonHelp.mapStr(json, 'metadata');
		return m;
	}
}

class PolymodError
{
	public var severity:PolymodErrorType;
	public var code:String;
	public var message:String;
	public var origin:PolymodErrorOrigin;

	public function new(severity:PolymodErrorType, code:PolymodErrorCode, message:String, origin:PolymodErrorOrigin)
	{
		this.severity = severity;
		this.code = code;
		this.message = message;
		this.origin = origin;
	}
}

/**
 * Indicates where the error occurred.
 */
@:enum abstract PolymodErrorOrigin(String) from String to String
{
	/**
	 * This error occurred while scanning for mods.
	 */
	var SCAN:String = 'scan';

	/**
	 * This error occurred while initializng Polymod.
	 */
	var INIT:String = 'init';

	/**
	 * This error occurred in an undefined location.
	 */
	var UNKNOWN:String = 'unknown';
}

/**
 * Represents the severity level of a given error.
 */
enum PolymodErrorType
{
	/**
	 * This message is merely an informational notice.
	 * You can handle it with a popup, log it, or simply ignore it.
	 */
	NOTICE;

	/**
	 * This message is a warning.
	 * Either the application developer, the mod developer, or the user did something wrong.
	 */
	WARNING;

	/**
	 * This message indicates a severe error occurred.
	 * This almost certainly will cause unintended behavior. A certain mod may not load or may even cause crashes.
	 */
	ERROR;
}

/**
 * Represents the particular type of error that occurred.
 * Great to use as the condition of a switch statement to provide various handling.
 */
@:enum abstract PolymodErrorCode(String) from String to String
{
	/**
	 * The mod's metadata file could not be parsed.
	 * - Make sure the file contains valid JSON.
	 */
	var PARSE_MOD_META:String = 'parse_mod_meta';

	/**
	 * The mod's version string could not be parsed.
	 * - Make sure the metadata JSON contains a valid Semantic Version string.
	 */
	var PARSE_MOD_VERSION:String = 'parse_mod_version';

	/**
	 * The mod's API version string could not be parsed.
	 * - Make sure the metadata JSON contains a valid Semantic Version string.
	 */
	var PARSE_MOD_API_VERSION:String = 'parse_mod_api_version';

	/**
	 * The app's API version string (passed to Polymod.init) could not be parsed.
	 * - Make sure the string is a valid Semantic Version string.
	 */
	var PARSE_API_VERSION:String = 'parse_api_version';

	/**
	 * You requested a mod to be loaded but that mod was not installed.
	 * - Make sure a mod with that name is installed.
	 * - Make sure to run Polymod.scan to get the list of valid mod IDs.
	 */
	var MISSING_MOD:String = 'missing_mod';

	/**
	 * You requested a mod to be loaded but its mod folder is missing a metadata file.
	 * - Make sure the mod folder contains a metadata JSON file. Polymod won't recognize the mod without it.
	 */
	var MISSING_META:String = 'missing_meta';

	/**
	 * A mod with the given ID is missing a metadata file.
	 * - This is a warning and can be ignored. Polymod will still load your mod, but it looks better if you add an icon.
	 * - The default location for icons is `_polymod_icon.png`.
	 */
	var MISSING_ICON:String = 'missing_icon';

	/**
	 * We are preparing to load a particular mod.
	 * - This is an info message. You can log it or ignore it if you like.
	 */
	var MOD_LOAD_PREPARE:String = 'mod_load_prepare';

	/**
	 * We couldn't load a particular mod.
	 * - There will generally be a warning or error before this indicating the reason for the error.
	 */
	var MOD_LOAD_FAILED:String = 'mod_load_failed';

	/**
	 * We have successfully completed loading a particular mod.
	 * - This is an info message. You can log it or ignore it if you like.
	 * - This is also a good trigger for a UI indicator like a toast notification.
	 */
	var MOD_LOAD_DONE:String = 'mod_load_done';

	/**
	 * You attempted to perform an operation that requires Polymod to be initialized.
	 * - Make sure you call Polymod.init before attempting to call this function.
	 */
	var POLYMOD_NOT_LOADED:String = 'polymod_not_loaded';

	/**
	 * The chosen script interpreter is not available.
	 * - This message is only displayed if the HScript-EX config option is enabled, while HScript-EX is not installed.
	 * - Either install the proper version of the `hscript-ex` library, or disable the config option.
	 */
	var SCRIPT_NO_INTERPRETER:String = 'script_no_interpreter';

	/**
	 * The scripted class does not import an `Assets` class to handle script loading.
	 * - When loading scripts, the target of the HScriptable interface will call `Assets.getText` to read the relevant script file.
	 * - You will need to import `openfl.util.Assets` on the HScriptable class, even if you don't otherwise use it.
	 */
	var SCRIPT_NO_ASSET_HANDLER:String = 'script_no_asset_handler';

	/**
	 * A script file of the given name could not be found.
	 * - Make sure the script file exists in the proper location in your assets folder.
	 * - Alternatively, you can expand your annotation to `@:hscript({optional: true})` to disable the error message,
	 *     as long as your application is built to function without it.
	 */
	var SCRIPT_NOT_FOUND:String = 'script_not_found';

	/**
	 * A script file of the given name could not be loaded for some unknown reason.
	 * - Check the syntax of the script file is proper Haxe.
	 */
	var SCRIPT_NOT_LOADED:String = 'script_not_loaded';

	/**
	 * When running a script, it threw a runtime exception.
	 * - The scripted function will assign the `script_error` variable, allowing you to handle the error gracefully.
	 */
	var SCRIPT_EXCEPTION:String = 'script_exception';

	/**
	 * An installed mod is looking for another mod with a specific version, but the mod is not of that version.
	 * - The mod may be a modpack that includes that mod, or it may be a mod that has the other mod as a dependency.
	 * - Inform your users to install the proper mod version.
	 */
	var VERSION_CONFLICT_MOD:String = 'version_conflict_mod';

	/**
	 * The mod has an API version that conflicts with the application's API version.
	 * - This means that the mod needs to be updated, checking for compatibility issues with any changes to API version.
	 * - If you're getting this error even for patch versions, be sure to tweak the `POLYMOD_API_VERSION_MATCH` config option.
	 */
	var VERSION_CONFLICT_API:String = 'version_conflict_api';

	/**
	 * A log warning thrown when the minor version of the mod differs from the minor version of the app, when the app version is 0.X.
	 * - This warning is provided to remind mod developers that early mod APIs can change drastically. This can be ignored if desired,
	 *   but should most likely be logged.
	 */
	var VERSION_PRERELEASE_API:String = 'version_prerelease_api';

	/**
	 * One of the version strings you provided to Polymod.init is invalid.
	 * - Make sure you're using a valid Semantic Version string.
	 */
	var PARAM_MOD_VERSION:String = 'param_mod_version';

	/**
	 * Indicates what asset framework Polymod has automatically detected for use.
	 * - This is an info message, and can either be logged or ignored.
	 */
	var FRAMEWORK_AUTODETECT:String = 'framework_autodetect';

	/**
	 * Indicates what asset framework Polymod has been manually configured to use.
	 * - This is an info message, and can either be logged or ignored.
	 */
	var FRAMEWORK_INIT:String = 'framework_init';

	/**
	 * You configured Polymod to use the `CUSTOM` asset framework, then didn't provide a value for `params.customBackend`.
	 * - Define a class which extends IBackend, and provide it to Polymod.
	 */
	var UNDEFINED_CUSTOM_BACKEND:String = 'undefined_custom_backend';

	/**
	 * Polymod could not create an instance of the class you provided for `params.customBackend`.
	 * - Check that the class extends IBackend, and can be instantiated properly.
	 */
	var FAILED_CREATE_BACKEND:String = 'failed_create_backend';

	/**
	 * You attempted to use a functionality of Polymod that is not fully implemented, or not implemented for the current framework.
	 * - Report the issue here, and describe your setup and provide the error message:
	 *   https://github.com/larsiusprime/polymod/issues
	 */
	var FUNCTIONALITY_NOT_IMPLEMENTED:String = 'functionality_not_implemented';

	/**
	 * You attempted to use a functionality of Polymod that has been deprecated and has/will be significantly reworked or altered.
	 * - New features and their associated documentation will be provided in future updates.
	 */
	var FUNCTIONALITY_DEPRECATED:String = 'functionality_deprecated';

	/**
	 * There was an error attempting to perform a merge operation on a file.
	 * - Check the source and target files are correctly formatted and try again.
	 */
	var MERGE:String = 'merge_error';

	/**
	 * There was an error attempting to perform an append operation on a file.
	 * - Check the source and target files are correctly formatted and try again.
	 */
	var APPEND:String = 'append_error';

	/**
	 * On the Lime and OpenFL platforms, if the base app defines multiple asset libraries,
	 * each asset library must be assigned a path to allow mods to override their files.
	 * - Provide a `frameworkParams.assetLibraryPaths` object to Polymod.init().
	 */
	var LIME_MISSING_ASSET_LIBRARY_INFO = 'lime_missing_asset_library_info';

	/**
	 * On the Lime and OpenFL platforms, if the base app defines multiple asset libraries,
	 * each asset library must be assigned a path to allow mods to override their files.
	 * - All libraries must have a value under `frameworkParams.assetLibraryPaths`.
	 * - Set the value to `./` to fetch assets from the root of the mod folder.
	 */
	var LIME_MISSING_ASSET_LIBRARY_REFERENCE = 'lime_missing_asset_library_reference';
}
