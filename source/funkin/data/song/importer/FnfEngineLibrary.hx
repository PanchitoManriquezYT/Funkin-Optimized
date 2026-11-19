package funkin.data.song.importer;

#if sys
import funkin.data.song.SongData.SongChartData;
import funkin.data.song.SongData.SongMetadata;
import funkin.data.song.importer.FnfEngineImporter.EngineImportResult;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * One song found in `psych-songs/`.
 */
typedef EngineSongSource =
{
  var id:String;
  var name:String;
  var dir:String;
  var charts:Array<String>;
  var audioDirs:Array<String>;

  /**
   * Codename Engine's `meta.json`, if the song has one.
   */
  var meta:Null<String>;
}

/**
 * Lets songs from other FNF engines be played as they are, next to the V-Slice ones (nothing of V-Slice is replaced).
 * Supported: Psych Engine 0.6.3 / 0.7.3 / 1.0.4, P-Slice, Kade Engine and Codename Engine.
 *
 * Put each song in its own folder inside `fnf-engines/` (next to the `mods` folder):
 *
 *     fnf-engines/My Song/my-song.json         (chart; `my-song-hard.json` etc. for other difficulties)
 *     fnf-engines/My Song/Inst.ogg
 *     fnf-engines/My Song/Voices.ogg           (optional; `Voices-Player.ogg` and `Voices-Opponent.ogg` work too)
 *     fnf-engines/My Song/events.json          (optional, Psych 0.6 / 0.7)
 *
 * The folder of a Codename Engine song works as it is (`charts/<difficulty>.json`, `meta.json`, `song/Inst.ogg`), and so does
 * the layout of a Psych Engine mod (`data/<song>/...` and `songs/<song>/...`).
 *
 * On startup the songs are converted into a generated mod (`mods/fnf-engines`), which the game loads like any other mod,
 * so they show up in Freeplay and in the online lobby. Songs that haven't changed are not converted again.
 */
class FnfEngineLibrary
{
  public static inline var SOURCE_FOLDER:String = 'fnf-engines';
  static inline var MOD_ID:String = 'fnf-engines';
  static inline var STAMP_FILE:String = '.engine-stamp';

  /**
   * Convert every song in `psych-songs/` into the generated mod inside `modRoot`. Never throws.
   * @return The ids of the songs that are available.
   */
  public static function sync(modRoot:String):Array<String>
  {
    var ids:Array<String> = [];
    try
    {
      var modDir:String = Path.join([modRoot, MOD_ID]);

      // The generated mod of the previous version (Psych-only) used another folder and would duplicate the songs.
      removeGenerated(Path.join([modRoot, 'psych-songs']), '.psych-stamp');

      if (!FileSystem.exists(SOURCE_FOLDER) || !FileSystem.isDirectory(SOURCE_FOLDER))
      {
        // Nothing to convert: don't leave the songs of a folder that was deleted.
        removeGenerated(modDir, STAMP_FILE);
        return ids;
      }
      var stamp:String = buildStamp();
      var stampPath:String = Path.join([modDir, STAMP_FILE]);

      var songs:Array<EngineSongSource> = findSongs();
      for (song in songs)
        ids.push(song.id);

      if (FileSystem.exists(stampPath) && File.getContent(stampPath) == stamp)
      {
        trace('[FnfEngineLibrary] ${ids.length} engine song(s), already converted.');
        return ids;
      }

      FileSystem.createDirectory(modRoot);
      // Start clean, so songs that were removed from the folder don't stay in the game.
      removeGenerated(modDir, STAMP_FILE);
      createDirectories(modDir);

      var converted:Array<String> = [];
      for (song in songs)
      {
        if (convertSong(song, modDir)) converted.push(song.id);
      }

      File.saveContent(Path.join([modDir, '_polymod_meta.json']), haxe.Json.stringify({
        title: 'FNF Engines songs',
        description: 'Generated from the fnf-engines folder. Do not edit: it is rebuilt when the folder changes.',
        author: 'Generated',
        api_version: funkin.modding.PolymodHandler.API_VERSION,
        mod_version: '1.0.0',
        license: 'Unknown'
      }, null, '  '));
      writeLevel(modDir, converted);
      File.saveContent(stampPath, stamp);
      trace('[FnfEngineLibrary] Converted ${converted.length} engine song(s).');
      return converted;
    }
    catch (e:Dynamic)
    {
      trace('[FnfEngineLibrary] Could not prepare the engine songs: $e');
      return ids;
    }
  }

  /**
   * A V-Slice song id for a folder name: lowercase, words joined by dashes.
   */
  public static function songIdFor(folder:String):String
  {
    var id:String = ~/[^a-z0-9]+/g.replace(folder.toLowerCase(), '-');
    id = ~/^-+|-+$/g.replace(id, '');
    return id == '' ? 'psych-song' : id;
  }

  /**
   * Find the songs: every folder that has a Psych chart in it. Both layouts work:
   *
   * - everything in one folder (`My Song/my-song.json`, `My Song/Inst.ogg`), or
   * - the layout of a Psych Engine mod, with `data/<song>/<song>.json` and `songs/<song>/Inst.ogg`
   *   (copy the mod's `data` and `songs` folders into a folder of `psych-songs`).
   */
  static function findSongs():Array<EngineSongSource>
  {
    var found:Array<EngineSongSource> = [];
    var usedIds:Map<String, Bool> = [];
    var stack:Array<String> = [SOURCE_FOLDER];

    while (stack.length > 0)
    {
      var dir:String = stack.pop();
      var entries:Array<String> = FileSystem.readDirectory(dir);
      entries.sort((a, b) -> a < b ? 1 : (a > b ? -1 : 0)); // Reversed: it's a stack, so folders come out in order.

      var charts:Array<String> = [];
      for (entry in entries)
      {
        var path:String = Path.join([dir, entry]);
        if (FileSystem.isDirectory(path)) stack.push(path);
        else if (isChartFile(entry))
          charts.push(path);
      }
      // Codename Engine: `<song>/charts/<difficulty>.json`, `<song>/meta.json`, `<song>/song/Inst.ogg`.
      var chartsDir:String = Path.join([dir, 'charts']);
      if (dir != SOURCE_FOLDER && FileSystem.exists(chartsDir) && FileSystem.isDirectory(chartsDir))
      {
        var codenameCharts:Array<String> = [
          for (file in FileSystem.readDirectory(chartsDir))
            if (isChartFile(file)) Path.join([chartsDir, file])
        ];
        if (codenameCharts.length > 0)
        {
          codenameCharts.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
          var codenameName:String = Path.withoutDirectory(dir);
          var codenameId:String = songIdFor(codenameName);
          var codenameUnique:String = codenameId;
          var codenameCopy:Int = 2;
          while (usedIds.exists(codenameUnique))
            codenameUnique = '$codenameId-${codenameCopy++}';
          usedIds.set(codenameUnique, true);

          var metaPath:String = Path.join([dir, 'meta.json']);
          found.push({
            id: codenameUnique,
            name: codenameName,
            dir: dir,
            charts: codenameCharts,
            audioDirs: [Path.join([dir, 'song']), dir],
            meta: FileSystem.exists(metaPath) ? File.getContent(metaPath) : null
          });
          // Don't also treat `charts/` as a song of its own.
          stack = stack.filter(p -> p != chartsDir);
          continue;
        }
      }

      if (charts.length == 0 || dir == SOURCE_FOLDER) continue;

      charts.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
      var name:String = Path.withoutDirectory(dir);
      var id:String = songIdFor(name);
      var unique:String = id;
      var copy:Int = 2;
      while (usedIds.exists(unique))
        unique = '$id-${copy++}';
      usedIds.set(unique, true);

      // Audio next to the charts, plus the `songs/<name>` folder of a Psych mod layout.
      var audioDirs:Array<String> = [dir];
      var parent:String = Path.directory(dir);
      if (Path.withoutDirectory(parent).toLowerCase() == 'data')
      {
        for (candidate in [Path.join([Path.directory(parent), 'songs', name])])
        {
          if (FileSystem.exists(candidate) && FileSystem.isDirectory(candidate)) audioDirs.push(candidate);
        }
      }

      found.push({id: unique, name: name, dir: dir, charts: charts, audioDirs: audioDirs, meta: null});
    }

    found.sort((a, b) -> a.id < b.id ? -1 : (a.id > b.id ? 1 : 0));
    return found;
  }

  static function isChartFile(file:String):Bool
  {
    var lower:String = file.toLowerCase();
    return StringTools.endsWith(lower, '.json') && lower != 'events.json' && !StringTools.startsWith(lower, '_');
  }

  static function convertSong(song:EngineSongSource, modDir:String):Bool
  {
    var base:Null<EngineImportResult> = null;
    var all:Array<EngineImportResult> = [];

    for (path in song.charts)
    {
      var result:Null<EngineImportResult> = FnfEngineImporter.importChart(File.getContent(path), Path.withoutDirectory(path), song.meta);
      if (result == null) continue;
      all.push(result);
      if (base == null || result.difficulty == 'normal') base = result;
    }

    if (base == null)
    {
      trace('[FnfEngineLibrary] No Psych chart found in "${song.dir}".');
      return false;
    }

    trace('[FnfEngineLibrary] ${song.name}: ${all.length} chart(s), ${base.sourceFormat} format.');

    var metadata:SongMetadata = base.metadata;
    var chart:SongChartData = base.chart;
    metadata.playData.difficulties = [];

    for (result in all)
    {
      if (metadata.playData.difficulties.contains(result.difficulty)) continue;
      metadata.playData.difficulties.push(result.difficulty);
      chart.notes.set(result.difficulty, result.chart.notes.get(result.difficulty) ?? []);
      chart.scrollSpeed.set(result.difficulty, result.chart.scrollSpeed.get(result.difficulty) ?? 1.0);
    }
    var order:Array<String> = ['easy', 'normal', 'hard', 'erect', 'nightmare'];
    metadata.playData.difficulties.sort((a, b) ->
    {
      var ia:Int = order.indexOf(a);
      var ib:Int = order.indexOf(b);
      return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
    });

    // Psych 0.6 and 0.7 keep the events in an `events.json` beside the charts. V-Slice shares events between difficulties.
    var eventsFile:String = Path.join([song.dir, 'events.json']);
    if (FileSystem.exists(eventsFile))
    {
      var extra = FnfEngineImporter.importEventsFile(File.getContent(eventsFile), metadata.timeChanges);
      if (extra != null)
      {
        chart.events = chart.events.concat(extra.events);
        chart.events.sort((a, b) -> a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
      }
    }

    var dataDir:String = Path.join([modDir, 'data', 'songs', song.id]);
    createDirectories(dataDir);
    File.saveContent(Path.join([dataDir, '${song.id}-metadata.json']), metadata.serialize());
    File.saveContent(Path.join([dataDir, '${song.id}-chart.json']), chart.serialize());

    var audioDir:String = Path.join([modDir, 'songs', song.id]);
    createDirectories(audioDir);
    for (dir in song.audioDirs)
    {
      if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) continue;
      for (file in FileSystem.readDirectory(dir))
      {
        var target:Null<String> = audioTargetName(file, metadata.playData.characters.player, metadata.playData.characters.opponent);
        if (target != null && !FileSystem.exists(Path.join([audioDir, target]))) File.copy(Path.join([dir, file]), Path.join([audioDir, target]));
      }
    }
    return true;
  }

  /**
   * The name an audio file has to have in V-Slice, or `null` if it isn't audio.
   * Psych 0.7+ / 1.0 split vocals into `Voices-Player` and `Voices-Opponent`, which V-Slice finds as `Voices-<character>`.
   */
  static function audioTargetName(file:String, player:String, opponent:String):Null<String>
  {
    var lower:String = file.toLowerCase();
    var dot:Int = lower.lastIndexOf('.');
    if (dot < 0) return null;
    var ext:String = lower.substr(dot);
    if (ext != '.ogg' && ext != '.mp3' && ext != '.wav') return null;

    var name:String = lower.substr(0, dot);
    if (name == 'inst') return 'Inst' + ext;
    if (name == 'voices') return 'Voices' + ext;
    if (name == 'voices-player') return 'Voices-' + player + ext;
    if (name == 'voices-opponent') return 'Voices-' + opponent + ext;
    return file;
  }

  static function writeLevel(modDir:String, songIds:Array<String>):Void
  {
    var dir:String = Path.join([modDir, 'data', 'levels']);
    createDirectories(dir);
    File.saveContent(Path.join([dir, 'fnfengines.json']), haxe.Json.stringify({
      version: '1.0.0',
      name: 'FNF ENGINES',
      titleAsset: 'storymenu/titles/tutorial',
      props: [],
      background: '#4B3F72',
      visible: false,
      songs: songIds
    }, null, '  '));
  }

  /**
   * Describes the source folder (names, sizes, dates) so that unchanged songs are skipped.
   */
  static function buildStamp():String
  {
    var parts:Array<String> = ['v3'];
    var stack:Array<String> = [SOURCE_FOLDER];
    while (stack.length > 0)
    {
      var dir:String = stack.pop();
      var entries:Array<String> = FileSystem.readDirectory(dir);
      entries.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
      for (entry in entries)
      {
        var path:String = Path.join([dir, entry]);
        var stat:sys.FileStat = FileSystem.stat(path);
        if (FileSystem.isDirectory(path)) stack.push(path);
        else
          parts.push('$path:${stat.size}:${Std.int(stat.mtime.getTime() / 1000)}');
      }
    }
    return parts.join('|');
  }

  /**
   * Delete a generated mod folder. Only folders that carry our stamp file are touched, never a mod made by hand.
   */
  static function removeGenerated(dir:String, stampFile:String):Void
  {
    if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) return;
    if (!FileSystem.exists(Path.join([dir, stampFile]))) return;
    deleteRecursively(dir);
  }

  static function deleteRecursively(path:String):Void
  {
    if (FileSystem.isDirectory(path))
    {
      for (entry in FileSystem.readDirectory(path))
        deleteRecursively(Path.join([path, entry]));
      FileSystem.deleteDirectory(path);
    }
    else
      FileSystem.deleteFile(path);
  }

  static function createDirectories(path:String):Void
  {
    var current:String = '';
    for (part in path.split('/'))
    {
      current = current == '' ? (part == '' ? '/' : part) : Path.join([current, part]);
      if (current != '/' && !FileSystem.exists(current)) FileSystem.createDirectory(current);
    }
  }
}
#end
