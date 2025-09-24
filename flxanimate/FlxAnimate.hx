package flxanimate;

import openfl.geom.Point;
import flxanimate.interfaces.IFilterable;
import openfl.display.BlendMode;
import flixel.graphics.frames.FlxFramesCollection;
import haxe.extern.EitherType;
import flxanimate.display.FlxAnimateFilterRenderer;
import openfl.filters.BitmapFilter;
import flxanimate.geom.FlxMatrix3D;
import openfl.display.Sprite;
import flixel.util.FlxColor;
import flixel.graphics.FlxGraphic;
import openfl.geom.Rectangle;
import openfl.display.BitmapData;
import flixel.util.FlxDestroyUtil;
import flixel.math.FlxRect;
import flixel.graphics.frames.FlxFrame;
import flixel.math.FlxPoint;
import flixel.FlxCamera;
import flxanimate.animate.*;
import flxanimate.zip.Zip;
import openfl.Assets;
import haxe.io.BytesInput;
#if (flixel >= "5.3.0")
import flixel.sound.FlxSound;
#else
import flixel.system.FlxSound;
#end
import flixel.FlxG;
import flxanimate.data.AnimationData;
import flixel.FlxSprite;
import flxanimate.animate.FlxAnim;
import flxanimate.frames.FlxAnimateFrames;
import flixel.math.FlxMatrix;
import openfl.geom.ColorTransform;
import flixel.math.FlxMath;
import flixel.FlxBasic;

using flixel.util.FlxColorTransformUtil;

typedef Settings = {
	?ButtonSettings:Map<String, flxanimate.animate.FlxAnim.ButtonSettings>,
	?FrameRate:Float,
	?Reversed:Bool,
	?OnComplete:Void->Void,
	?ShowPivot:Bool,
	?Antialiasing:Bool,
	?ScrollFactor:FlxPoint,
	?Offset:FlxPoint,
}

@:access(openfl.geom.ColorTransform)
@:access(openfl.geom.Rectangle)
@:access(flixel.graphics.frames.FlxFrame)
@:access(flixel.FlxCamera)
class FlxAnimate extends FlxSprite
{
	public var anim(default, null):FlxAnim;
	var rect:Rectangle;

	public var filters:Array<BitmapFilter> = null;
	public var showPivot(default, set):Bool = false;

	var _pivot:FlxFrame;
	var _indicator:FlxFrame;
	var renderer:FlxAnimateFilterRenderer = new FlxAnimateFilterRenderer();
	var filterCamera:FlxCamera;

	public var relativeX:Float = 0;
	public var relativeY:Float = 0;

	public function new(X:Float = 0, Y:Float = 0, ?directoryPath:String, ?Settings:Settings)
	{
		super(X, Y);
		anim = new FlxAnim(this);
		showPivot = false;
		if (directoryPath != null) loadAtlas(directoryPath);
		if (Settings != null) setTheSettings(Settings);
		rect = Rectangle.__pool.get();
	}

	/**
	 * Load atlas from folder or zip.
	 */
	public function loadAtlas(atlasDirectory:String)
	{
		var p = haxe.io.Path.removeTrailingSlashes(haxe.io.Path.normalize(atlasDirectory));
		if (!Assets.exists('$atlasDirectory/Animation.json') 
			&& !(Assets.exists('$atlasDirectory/data.json') && Assets.exists('$atlasDirectory/library.json')) 
			&& haxe.io.Path.extension(atlasDirectory) != "zip")
		{
			FlxG.log.error('No valid Animation.json or data.json+library.json found in "${atlasDirectory}"');
			return;
		}

		var animJson = atlasSetting(atlasDirectory);
		var frames = FlxAnimateFrames.fromTextureAtlas(atlasDirectory);
		loadSeparateAtlas(animJson, frames);
	}

	/**
	 * Parse + load normalized JSON and frame collection.
	 */
	public function loadSeparateAtlas(?animation:String = null, ?frames:FlxFramesCollection = null)
	{
		if (frames != null) this.frames = frames;
		if (animation != null)
		{
			var json:AnimAtlas = haxe.Json.parse(animation);
			anim._loadAtlas(json);
			if (anim != null && anim.curInstance != null)
				origin = anim.curInstance.symbol.transformationPoint;
		}
	}

	/**
	 * Try to load Animation.json OR normalize Animate exports (data.json + library.json).
	 */
	function atlasSetting(directoryPath:String):String
	{
		var jsontxt:String = null;

		if (haxe.io.Path.extension(directoryPath) == "zip")
		{
			var thing = Zip.readZip(Assets.getBytes(directoryPath));
			for (list in Zip.unzip(thing))
			{
				if (list.fileName.indexOf("Animation.json") != -1)
				{
					jsontxt = list.data.toString();
					thing.remove(list);
					continue;
				}
				if (list.fileName.indexOf("data.json") != -1)
				{
					var dataTxt = list.data.toString();
					var libTxt:String = null;
					for (l in thing) if (l.fileName.indexOf("library.json") != -1) libTxt = l.data.toString();
					if (libTxt != null) jsontxt = convertAnimateToAnimationJson(dataTxt, libTxt);
				}
			}
			@:privateAccess
			FlxAnimateFrames.zip = thing;
		}
		else
		{
			if (Assets.exists('$directoryPath/Animation.json'))
				jsontxt = Assets.getText('$directoryPath/Animation.json');
			else if (Assets.exists('$directoryPath/data.json') && Assets.exists('$directoryPath/library.json'))
				jsontxt = convertAnimateToAnimationJson(
					Assets.getText('$directoryPath/data.json'),
					Assets.getText('$directoryPath/library.json')
				);
		}
		return jsontxt;
	}

	/**
	 * Convert Animate's data.json + library.json into Animation.json
	 */
	function convertAnimateToAnimationJson(dataTxt:String, libTxt:String):String
	{
		var data = haxe.Json.parse(dataTxt);
		var lib = haxe.Json.parse(libTxt);

		var anim:Dynamic = {
			MD: { FRT: 24.0 },
			SD: { S: [] },
			AN: { TL: { L: [] } }
		};

		if (Reflect.hasField(lib, "symbols"))
		{
			for (sym in (lib.symbols:Array<Dynamic>))
			{
				anim.SD.S.push({ SN: sym.name, TL: { L: [] } });
			}
		}

		if (Reflect.hasField(data, "ANIMATIONS"))
		{
			for (a in (data.ANIMATIONS:Array<Dynamic>))
			{
				anim.AN.TL.L.push({
					LN: a.className,
					FR: [ { I: 0, DU: a.duration != null ? a.duration : 1, ref: a.className } ]
				});
			}
		}

		return haxe.Json.stringify(anim);
	}

	// ───────────────────────────────────────────
	// (rest of draw, parseElement, renderLayer etc. stays same as your file)
	// ───────────────────────────────────────────

}
