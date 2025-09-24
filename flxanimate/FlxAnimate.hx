package flxanimate;

import openfl.geom.Point;
import openfl.display.BlendMode;
import openfl.display.BitmapData;
import openfl.geom.ColorTransform;
import openfl.geom.Rectangle;
import openfl.Assets;

import flixel.FlxG;
import flixel.FlxBasic;
import flixel.FlxSprite;
import flixel.FlxCamera;
import flixel.graphics.FlxGraphic;
import flixel.graphics.frames.FlxFrame;
import flixel.graphics.frames.FlxFramesCollection;
import flixel.math.FlxMatrix;
import flixel.math.FlxPoint;
import flixel.util.FlxDestroyUtil;

import flxanimate.animate.*;
import flxanimate.display.FlxAnimateFilterRenderer;
import flxanimate.frames.FlxAnimateFrames;
import flxanimate.interfaces.IFilterable;
import flxanimate.zip.Zip;

#if (flixel >= "5.3.0")
import flixel.sound.FlxSound;
#else
import flixel.system.FlxSound;
#end

#if sys
import sys.FileSystem;
import sys.io.File;
#end

using StringTools;

/**
 * Extended FlxAnimate that also understands:
 *  - Standard FlxAnimate atlases (Animation.json + spritemaps)
 *  - Animate/OpenFL-SWF style folders: data.json, library.json, symbols/
 *    (We pack symbols into a runtime atlas and synthesize Animation.json on the fly)
 */
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
	var renderer:FlxAnimateFilterRenderer = new FlxAnimateFilterRenderer();
	var filterCamera:FlxCamera;

	public var filters:Array<openfl.filters.BitmapFilter> = null;
	public var showPivot(default, set):Bool = false;

	var _pivot:FlxFrame;
	var _indicator:FlxFrame;

	public var relativeX:Float = 0;
	public var relativeY:Float = 0;

	// scratch objects
	var _mat:FlxMatrix = new FlxMatrix();
	var _tmpMat:FlxMatrix = new FlxMatrix();
	var _col:ColorTransform = new ColorTransform();
	var _camArr:Array<FlxCamera> = [null];
	var _elemObj:{instance:FlxElement} = {instance: null};

	public function new(X:Float = 0, Y:Float = 0, ?directoryPath:String, ?Settings:Settings)
	{
		super(X, Y);
		anim = new FlxAnim(this);
		if (directoryPath != null) loadAtlas(directoryPath);
		if (Settings != null) setTheSettings(Settings);
		rect = Rectangle.__pool.get();
	}

	/**
	 * Load an atlas by directory folder or .zip.
	 * - Standard: requires Animation.json in the directory.
	 * - Animate mode: if no Animation.json but has data.json + library.json + symbols/
	 *   we synthesize a runtime atlas & JSON automatically.
	 */
	public function loadAtlas(dirOrZip:String)
	{
		final ext = haxe.io.Path.extension(dirOrZip);

		if (ext == "zip") {
			loadZipAtlas(dirOrZip);
			return;
		}

		// Try standard first (Animation.json present)
		if (existsText(dirOrZip + "/Animation.json")) {
			loadSeparateAtlas(getText(dirOrZip + "/Animation.json"), FlxAnimateFrames.fromTextureAtlas(dirOrZip));
			if (anim != null && anim.curInstance != null) origin = anim.curInstance.symbol.transformationPoint;
			return;
		}

		// Try "metadata.json" path (FlxAnimate extended frames) if present
		if (existsText(dirOrZip + "/metadata.json")) {
			loadSeparateAtlas(null, FlxAnimateFrames.fromTextureAtlas(dirOrZip));
			anim._loadExAtlas(dirOrZip);
			if (anim != null && anim.curInstance != null) origin = anim.curInstance.symbol.transformationPoint;
			return;
		}

		// Animate/OpenFL SWF style: data.json + library.json + symbols/
		final hasData = existsText(dirOrZip + "/data.json");
		final hasLib  = existsText(dirOrZip + "/library.json");
		#if sys
		final hasSymbols = FileSystem.exists(dirOrZip + "/symbols") && FileSystem.isDirectory(dirOrZip + "/symbols");
		#else
		final hasSymbols = false;
		#end

		if (hasData && hasLib && hasSymbols) {
			loadAnimateFolder(dirOrZip);
			return;
		}

		FlxG.log.error('FlxAnimate: Could not find supported atlas in "$dirOrZip". Expected Animation.json OR data.json+library.json+symbols/.');
	}

	/**
	 * ZIP loader: prefers Animation.json in zip. If not present, tries data.json/library.json/symbols entries in zip.
	 */
	function loadZipAtlas(zipPath:String)
	{
		var bytes = Assets.getBytes(zipPath);
		if (bytes == null) {
			FlxG.log.error('FlxAnimate: Zip not found in assets: $zipPath');
			return;
		}
		var zip = Zip.readZip(bytes);
		var entries = Zip.unzip(zip);

		var animJSON:String = null;
		var hasMeta = false;
		var hasData = false;
		var hasLib  = false;
		var dataJSON:String = null;
		var libJSON:String  = null;

		// collect zip filenames
		var symbolFiles:Array<{path:String, png:BitmapData}> = [];

		for (e in entries) {
			var name = e.fileName;
			if (name.endsWith("Animation.json")) {
				animJSON = e.data.toString();
			} else if (name.endsWith("metadata.json")) {
				hasMeta = true;
			} else if (name.endsWith("data.json")) {
				dataJSON = e.data.toString();
				hasData = true;
			} else if (name.endsWith("library.json")) {
				libJSON = e.data.toString();
				hasLib = true;
			} else if (name.indexOf("symbols/") != -1 && (name.toLowerCase().endsWith(".png"))) {
				// load each PNG in memory
				var imgBytes = e.data;
				var bmp = BitmapData.fromBytes(imgBytes);
				if (bmp != null) symbolFiles.push({path: name, png: bmp});
			}
		}

		// Standard
		if (animJSON != null) {
			@:privateAccess FlxAnimateFrames.zip = zip;
			loadSeparateAtlas(animJSON, FlxAnimateFrames.fromTextureAtlas(zipPath));
			if (anim != null && anim.curInstance != null) origin = anim.curInstance.symbol.transformationPoint;
			return;
		}

		// metadata frames path
		if (hasMeta) {
			@:privateAccess FlxAnimateFrames.zip = zip;
			loadSeparateAtlas(null, FlxAnimateFrames.fromTextureAtlas(zipPath));
			anim._loadExAtlas(zipPath);
			if (anim != null && anim.curInstance != null) origin = anim.curInstance.symbol.transformationPoint;
			return;
		}

		// Animate folder in zip
		if (hasData && hasLib && symbolFiles.length > 0) {
			loadAnimateFromZip(dataJSON, libJSON, symbolFiles);
			return;
		}

		FlxG.log.error('FlxAnimate: Zip missing supported content (Animation.json or data.json+library.json+symbols).');
	}

	/**
	 * Standard FlxAnimate entry: combine frames (optional) + JSON text
	 */
	public function loadSeparateAtlas(?animation:String = null, ?frames:FlxFramesCollection = null)
	{
		if (frames != null) this.frames = frames;
		if (animation != null) {
			var json:AnimAtlas = haxe.Json.parse(animation);
			anim._loadAtlas(json);
			if (anim != null && anim.curInstance != null)
				origin = anim.curInstance.symbol.transformationPoint;
		}
	}

	// === Animate/OpenFL SWF style support (folder) ===

	function loadAnimateFolder(root:String)
	{
		var dataTxt = getText(root + "/data.json");
		var libTxt  = getText(root + "/library.json");
		#if sys
		var symRoot = root + "/symbols";
		var collected = collectSymbolPNGs(symRoot);
		if (collected.length == 0) {
			FlxG.log.error('FlxAnimate: No PNGs found under symbols/ in "$root".');
			return;
		}
		buildRuntimeAtlasAndLoad(dataTxt, libTxt, collected);
		#else
		FlxG.log.error('FlxAnimate: symbols/ reading requires sys target.');
		#end
	}

	// === Animate/OpenFL SWF style support (zip) ===

	function loadAnimateFromZip(dataTxt:String, libTxt:String, symbolFiles:Array<{path:String, png:BitmapData}>)
	{
		if (symbolFiles == null || symbolFiles.length == 0) {
			FlxG.log.error('FlxAnimate: no symbols PNGs inside zip.');
			return;
		}
		buildRuntimeAtlasAndLoad(dataTxt, libTxt, symbolFiles);
	}

	// === Runtime pack & synthesize Animation.json ===

	/**
	 * Pack all symbol PNGs into one atlas BitmapData, create frames collection, and synthesize a simple Animation.json that references those frames.
	 */
	function buildRuntimeAtlasAndLoad(dataTxt:String, libTxt:String, images:Array<{path:String, png:BitmapData}>)
	{
		// 1) pack PNGs into a single bitmap (simple shelf packer: rows)
		var packing = packImagesShelf(images, 4096); // max width 4096
		var atlasBmp = packing.atlas;
		var rects = packing.rects; // maps image.path => Rectangle

		// 2) build a frames collection on this atlas
		var atlasGraphic = FlxGraphic.fromBitmapData(atlasBmp, false, 'flxanimate_runtime_atlas_' + Std.random(0xFFFFFF));
		var framesColl = new FlxFramesCollection(atlasGraphic, flixel.graphics.frames.FlxFrameCollectionType.ATLAS);
		for (img in images) {
			var r = rects.get(img.path);
			var fr = new FlxFrame(framesColl);
			fr.name = img.path; // keep original "symbols/..." path as frame name
			fr.parent = framesColl;
			fr.setFrame(r);
			framesColl.addFrame(fr);
		}

		// 3) synthesize Animation.json using data.json + library.json + discovered symbol frame names
		var animJSON = convertAnimateToAnimationJson(dataTxt, libTxt, images);

		// 4) load into FlxAnimate
		this.frames = framesColl;
		loadSeparateAtlas(animJSON, null);
	}

	/**
	 * Make an Animation.json that points to the collected symbol frames.
	 * - Uses "className" as animation LN where present in data.json; else uses symbol names from library.json.
	 * - Keeps frame names as their "symbols/.../file.png" strings.
	 */
	function convertAnimateToAnimationJson(dataTxt:String, libTxt:String, images:Array<{path:String, png:BitmapData}>):String
	{
		var data:Dynamic = null;
		var lib:Dynamic = null;
		try data = haxe.Json.parse(dataTxt) catch (e) {}
		try lib  = haxe.Json.parse(libTxt)  catch (e) {}

		// Group images by top-level symbol folder: symbols/<SYMBOL>/<file>.png
		var bySymbol:Map<String, Array<String>> = new Map();
		for (it in images) {
			var p = it.path;
			var parts = p.split("/");
			var sym = (parts.length >= 2) ? parts[1] : "symbol";
			if (!bySymbol.exists(sym)) bySymbol.set(sym, []);
			bySymbol.get(sym).push(p);
		}
		// sort each symbol's frames for deterministic order
		for (k in bySymbol.keys()) bySymbol.get(k).sort((a, b) -> Reflect.compare(a, b));

		// Build minimal FlxAnimate "AnimAtlas" JSON
		var anim:Dynamic = {
			MD: { FRT: extractFrameRate(data, 24.0) },
			SD: { S: [] },
			AN: { TL: { L: [] } }
		};

		// Symbol definitions
		for (symName in bySymbol.keys()) {
			var framesArr = [];
			var i = 0;
			for (fname in bySymbol.get(symName)) {
				framesArr.push({
					I: i,
					DU: 1,
					// we keep reference name identical to frameName (symbols/.../file.png)
					ref: fname
				});
				i++;
			}
			anim.SD.S.push({
				SN: symName,
				TL: { L: [ { FR: framesArr } ] }
			});
		}

		// Timeline list: try to use data.ANIMATIONS[].className; else one timeline per symbol
		var added = false;
		if (data != null && Reflect.hasField(data, "ANIMATIONS")) {
			var arr:Array<Dynamic> = data.ANIMATIONS;
			for (a in arr) {
				if (a != null && Reflect.hasField(a, "className")) {
					var name:String = a.className;
					anim.AN.TL.L.push({
						LN: name,
						FR: [ { I: 0, DU: 1, ref: name } ]
					});
					added = true;
				}
			}
		}
		if (!added) {
			for (symName in bySymbol.keys()) {
				anim.AN.TL.L.push({
					LN: symName,
					FR: [ { I: 0, DU: 1, ref: symName } ]
				});
			}
		}

		return haxe.Json.stringify(anim);
	}

	inline function extractFrameRate(data:Dynamic, fallback:Float):Float
	{
		if (data == null) return fallback;
		// try typical places
		if (Reflect.hasField(data, "MD") && Reflect.hasField(data.MD, "FRT")) {
			var v:Dynamic = data.MD.FRT;
			if (Std.isOfType(v, Float) || Std.isOfType(v, Int)) return v;
		}
		if (Reflect.hasField(data, "frameRate")) {
			var v2:Dynamic = data.frameRate;
			if (Std.isOfType(v2, Float) || Std.isOfType(v2, Int)) return v2;
		}
		return fallback;
	}

	// === packing ===

	private function packImagesShelf(images:Array<{path:String, png:BitmapData}>, maxWidth:Int):{ atlas:BitmapData, rects:Map<String, Rectangle> }
	{
		// simple shelf packer: fill rows up to maxWidth,
		// compute total size, then blit.
		var rows = [];
		var curRow = [];
		var x = 0;
		var rowH = 0;
		var totalW = 0;
		var totalH = 0;

		for (it in images) {
			var w = it.png.width;
			var h = it.png.height;
			if (x > 0 && x + w > maxWidth) {
				// close row
				rows.push({ items: curRow.copy(), width: x, height: rowH });
				totalW = Std.int(Math.max(totalW, x));
				totalH += rowH;
				// new row
				curRow.resize(0);
				x = 0;
				rowH = 0;
			}
			curRow.push(it);
			x += w;
			if (h > rowH) rowH = h;
		}
		if (curRow.length > 0) {
			rows.push({ items: curRow.copy(), width: x, height: rowH });
			totalW = Std.int(Math.max(totalW, x));
			totalH += rowH;
		}

		if (totalW <= 0) totalW = 1;
		if (totalH <= 0) totalH = 1;

		var atlas = new BitmapData(totalW, totalH, true, 0x00000000);
		var rects:Map<String, Rectangle> = new Map();

		var y = 0;
		for (row in rows) {
			var xx = 0;
			for (it in row.items) {
				var r = new Rectangle(xx, y, it.png.width, it.png.height);
				atlas.copyPixels(it.png, it.png.rect, new openfl.geom.Point(xx, y), null, null, true);
				rects.set(it.path, r);
				xx += it.png.width;
			}
			y += row.height;
		}

		return { atlas: atlas, rects: rects };
	}

	// === Helpers ===

	inline function _singleCam(cam:FlxCamera):Array<FlxCamera> { _camArr[0] = cam; return _camArr; }
	inline function _elemInstance(?instance:FlxElement) { _elemObj.instance = instance; return _elemObj; }

	#if sys
	function collectSymbolPNGs(symbolsRoot:String):Array<{path:String, png:BitmapData}>
	{
		var out:Array<{path:String, png:BitmapData}> = [];
		if (!FileSystem.exists(symbolsRoot) || !FileSystem.isDirectory(symbolsRoot)) return out;

		for (sym in FileSystem.readDirectory(symbolsRoot)) {
			var symPath = symbolsRoot + "/" + sym;
			if (!FileSystem.isDirectory(symPath)) continue;
			for (fn in FileSystem.readDirectory(symPath)) {
				if (!fn.toLowerCase().endsWith(".png")) continue;
				var full = symPath + "/" + fn;
				try {
					var bmp = BitmapData.fromFile(full); // sync on native
					if (bmp != null) {
						// store a normalized "symbols/.../file.png" path as key to use as frame name
						var logical = "symbols/" + sym + "/" + fn;
						out.push({ path: logical, png: bmp });
					}
				} catch (e) {
					FlxG.log.warn('FlxAnimate: failed to load PNG "$full": $e');
				}
			}
		}
		return out;
	}
	#end

	inline function existsText(path:String):Bool
	{
		#if sys
		if (FileSystem.exists(path) && !FileSystem.isDirectory(path)) return true;
		#end
		return Assets.exists(path);
	}

	inline function getText(path:String):String
	{
		#if sys
		try {
			if (FileSystem.exists(path) && !FileSystem.isDirectory(path))
				return File.getContent(path);
		} catch (_) {}
		#end
		return Assets.getText(path);
	}

	// ===== Drawing / core render (unchanged, just tidied) =====

	public override function draw():Void
	{
		if (alpha <= 0) return;

		_matrix.identity();
		if (flipX) _matrix.a *= -1;
		if (flipY) _matrix.d *= -1;

		_flashRect.setEmpty();
		parseElement(anim.curInstance, _matrix, colorTransform, cameras, scrollFactor);

		width = _flashRect.width;
		height = _flashRect.height;
		frameWidth = Math.round(width);
		frameHeight = Math.round(height);

		relativeX = _flashRect.x - x;
		relativeY = _flashRect.y - y;

		if (showPivot)
		{
			_tmpMat.setTo(1, 0, 0, 1, origin.x - _pivot.frame.width * 0.5, origin.y - _pivot.frame.height * 0.5);
			drawLimb(_pivot, _tmpMat, cameras);

			_tmpMat.setTo(1, 0, 0, 1, -_indicator.frame.width * 0.5, -_indicator.frame.height * 0.5);
			drawLimb(_indicator, _tmpMat, cameras);
		}
	}

	function parseElement(instance:FlxElement, m:FlxMatrix, colorFilter:ColorTransform, ?cameras:Array<FlxCamera> = null, ?scrollFactor:FlxPoint = null)
	{
		if (instance == null || !instance.visible) return;

		var mainSymbol = instance == anim.curInstance;
		var skipFilters = anim.metadata.skipFilters;

		if (cameras == null) cameras = this.cameras;

		var matrix = instance._matrix;
		matrix.copyFrom(instance.matrix);
		matrix.translate(instance.x, instance.y);
		matrix.concat(m);

		var colorEffect = instance._color;
		colorEffect.__copyFrom(colorFilter);

		var symbol = (instance.symbol != null) ? anim.symbolDictionary.get(instance.symbol.name) : null;
		if (instance.bitmap == null && symbol == null) return;

		if (instance.bitmap != null)
		{
			drawLimb(frames.getByName(instance.bitmap), matrix, colorEffect, false, cameras);
			return;
		}

		// No filter caching here to keep code compact & robust
		if (instance.symbol.colorEffect != null)
			colorEffect.concat(instance.symbol.colorEffect.c_Transform);

		var firstFrame:Int = instance.symbol._curFrame;
		switch (instance.symbol.type) {
			case Button: firstFrame = setButtonFrames(firstFrame);
			default:
		}

		var layers = symbol.timeline.getList();
		for (i in 0...layers.length)
		{
			var layer = layers[layers.length - 1 - i];
			if (!layer.visible && (mainSymbol || !anim.metadata.showHiddenLayers)) continue;

			layer._setCurFrame(firstFrame);
			var frame = layer._currFrame;
			if (frame == null) continue;

			var coloreffect = _col;
			coloreffect.__copyFrom(colorEffect);
			if (frame.colorEffect != null)
				coloreffect.concat(frame.colorEffect.__create());

			_tmpMat.identity();
			renderLayer(frame, matrix, coloreffect, cameras);
		}
	}

	inline function renderLayer(frame:FlxKeyFrame, matrix:FlxMatrix, colorEffect:ColorTransform, cameras:Array<FlxCamera>)
	{
		for (element in frame.getList())
		{
			// recurse
			if (element.bitmap != null) {
				drawLimb(frames.getByName(element.bitmap), matrix, colorEffect, false, cameras);
			} else {
				parseElement(element, matrix, colorEffect, cameras);
			}
		}
	}

	function setButtonFrames(frame:Int)
	{
		var badPress = false;
		var goodPress = false;
		#if FLX_MOUSE
		if (FlxG.mouse.pressed && FlxG.mouse.overlaps(this)) goodPress = true;
		if (FlxG.mouse.pressed && !FlxG.mouse.overlaps(this) && !goodPress) badPress = true;
		if (!FlxG.mouse.pressed) { badPress = false; goodPress = false; }
		if (FlxG.mouse.overlaps(this) && !badPress)
		{
			@:privateAccess
			var event = anim.buttonMap.get(anim.curSymbol.name);
			if (FlxG.mouse.justPressed)
				if (event != null) new ButtonEvent((event.Callbacks != null) ? event.Callbacks.OnClick : null #if FLX_SOUND_SYSTEM, event.Sound #end).fire();
			frame = (FlxG.mouse.pressed) ? 2 : 1;
			if (FlxG.mouse.justReleased)
				if (event != null) new ButtonEvent((event.Callbacks != null) ? event.Callbacks.OnRelease : null #if FLX_SOUND_SYSTEM, event.Sound #end).fire();
		} else frame = 0;
		#end
		return frame;
	}

	function drawLimb(limb:FlxFrame, _matrix:FlxMatrix, ?colorTransform:ColorTransform = null, filterin:Bool = false, ?cameras:Array<FlxCamera> = null)
	{
		if (colorTransform != null && (colorTransform.alphaMultiplier == 0 || colorTransform.alphaOffset == -255) || limb == null || limb.type == EMPTY)
			return;
		if (cameras == null) cameras = this.cameras;

		for (camera in cameras)
		{
			var matrix = _mat;
			matrix.identity();
			limb.prepareMatrix(matrix);
			matrix.concat(_matrix);

			if (camera == null || !camera.visible || !camera.exists) return;

			if (!filterin)
			{
				getScreenPosition(_point, camera).subtractPoint(offset);

				matrix.translate(-origin.x, -origin.y);
				matrix.scale(scale.x, scale.y);
				if (bakedRotationAngle <= 0) {
					updateTrig();
					if (angle != 0) matrix.rotateWithTrig(_cosAngle, _sinAngle);
				}
				_point.addPoint(origin);

				if (isPixelPerfectRender(camera)) _point.floor();
				matrix.translate(_point.x, _point.y);

				if (!limbOnScreen(limb, matrix, camera)) continue;
			}

			camera.drawPixels(limb, null, matrix, colorTransform, BlendMode.NORMAL, (!filterin) ? antialiasing : true, this.shader);
		}

		width = rect.width;
		height = rect.height;
		frameWidth = Std.int(width);
		frameHeight = Std.int(height);

		#if FLX_DEBUG
		if (FlxG.debugger.drawDebug && limb != _pivot && limb != _indicator)
		{
			var oldX = x; var oldY = y;
			x = rect.x; y = rect.y;
			drawDebug();
			x = oldX; y = oldY;
		}
		FlxBasic.visibleCount++;
		#end
	}

	function limbOnScreen(limb:FlxFrame, m:FlxMatrix, ?Camera:FlxCamera = null)
	{
		if (Camera == null) Camera = FlxG.camera;
		limb.frame.copyToFlash(rect);
		rect.offset(-rect.x, -rect.y);
		rect.__transform(rect, m);
		_point.copyFromFlash(rect.topLeft);
		_flashRect = _flashRect.union(rect);
		return Camera.containsPoint(_point, rect.width, rect.height);
	}

	override function destroy()
	{
		anim = FlxDestroyUtil.destroy(anim);

		_mat = null; _tmpMat = null; _col = null;
		_camArr = null; _elemObj = null;

		super.destroy();
	}

	public override function updateAnimation(elapsed:Float)
	{
		anim.update(elapsed);
	}

	public function setButtonPack(button:String, callbacks:ClickStuff #if FLX_SOUND_SYSTEM , sound:FlxSound #end):Void
	{
		@:privateAccess
		anim.buttonMap.set(button, {Callbacks: callbacks, #if FLX_SOUND_SYSTEM Sound:  sound #end});
	}

	function set_showPivot(value:Bool)
	{
		if (value != showPivot)
		{
			showPivot = value;
			if (showPivot && _pivot == null)
			{
				_pivot = FlxGraphic.fromBitmapData(Assets.getBitmapData("flxanimate/images/pivot.png"), "__pivot").imageFrame.frame;
				_indicator = FlxGraphic.fromBitmapData(Assets.getBitmapData("flxanimate/images/indicator.png"), "__indicator").imageFrame.frame;
			}
		}
		return value;
	}

	public function setTheSettings(?Settings:Settings):Void
	{
		@:privateAccess
		{
			antialiasing = Settings.Antialiasing;
			if (Settings.ButtonSettings != null) {
				anim.buttonMap = Settings.ButtonSettings;
				if (anim.symbolType != Button) anim.symbolType = Button;
			}
			if (Settings.Reversed != null) anim.reversed = Settings.Reversed;
			if (Settings.FrameRate != null) anim.framerate = (Settings.FrameRate <= 0) ? anim.metadata.frameRate : Settings.FrameRate;
			if (Settings.OnComplete != null) anim.onComplete.add(Settings.OnComplete);
			if (Settings.ShowPivot != null) showPivot = Settings.ShowPivot;
			if (Settings.Antialiasing != null) antialiasing = Settings.Antialiasing;
			if (Settings.ScrollFactor != null) scrollFactor = Settings.ScrollFactor;
			if (Settings.Offset != null) offset = Settings.Offset;
		}
	}
}
