package funkin.data.song.importer;

import funkin.data.song.SongData.SongCharacterData;
import funkin.data.song.SongData.SongChartData;
import funkin.data.song.SongData.SongEventData;
import funkin.data.song.SongData.SongMetadata;
import funkin.data.song.SongData.SongNoteData;
import funkin.data.song.SongData.SongTimeChange;

/**
 * Everything that came out of reading a chart from another FNF engine.
 */
typedef EngineImportResult =
{
  /**
   * The song's metadata (name, BPM changes, characters, stage).
   */
  var metadata:SongMetadata;

  /**
   * The chart (notes, events and scroll speed).
   */
  var chart:SongChartData;

  /**
   * The difficulty the notes were imported as.
   */
  var difficulty:String;

  /**
   * Which engine and version wrote the chart, e.g. `Psych 0.6 / Kade`, `Psych 1.0` or `Codename`.
   */
  var sourceFormat:String;

  /**
   * Names of events that have no V-Slice equivalent and were left out (each name once).
   */
  var skippedEvents:Array<String>;

  /**
   * How many notes used a special note type that V-Slice doesn't have. They were imported as normal notes.
   */
  var skippedNoteTypes:Int;
}

/**
 * Imports charts made for other FNF engines and converts them to V-Slice. Based on the logic of Chart Converter
 * (https://github.com/panchitomanriquezxdxd/ChartConverter), which does the same outside of the game.
 *
 * - Psych Engine 0.6.3 / Kade Engine / older: `{"song": {...}}`, lanes relative to `mustHitSection`.
 * - Psych Engine 0.7.3: the same, events may also be written inside `sectionNotes`.
 * - Psych Engine 1.0.4 / P-Slice (`"format": "psych_v1"`): fields at the root, absolute lanes.
 * - Codename Engine: `strumLines` / `events`, with the BPM and difficulties in `meta.json`.
 *
 * The JSON is read as plain dynamic data, so unexpected or missing fields don't make the import fail.
 */
@:nullSafety
class FnfEngineImporter
{
  static final STRUMLINE_SIZE:Int = 4;

  /**
   * How many beats a section lasts when the chart doesn't say (every Psych version defaults to 4).
   */
  static final DEFAULT_SECTION_BEATS:Float = 4.0;

  /**
   * Psych's stage names and the V-Slice stage they correspond to. Other names are kept as they are.
   */
  static final STAGE_NAMES:Map<String, String> = [
    'stage' => 'mainStage',
    'spooky' => 'spookyMansion',
    'philly' => 'phillyTrain',
    'limo' => 'limoRide',
    'mall' => 'mallXmas',
    'mallEvil' => 'mallEvil',
    'school' => 'school',
    'schoolEvil' => 'schoolEvil',
    'tank' => 'tankmanBattlefield',
  ];

  /**
   * Whether a parsed JSON value looks like a chart of a supported engine.
   */
  public static function isEngineChart(root:Null<Dynamic>):Bool
  {
    return songObject(root) != null || codenameObject(root) != null;
  }

  /**
   * Read a chart file.
   * @param content The JSON text.
   * @param fileName The file's name, used for the song name and difficulty when the chart doesn't say (`bopeebo-hard.json`).
   * @param metaContent Codename Engine keeps the BPM, name and difficulties in a separate `meta.json`: its text, if any.
   * @return The imported song, or `null` if it isn't a chart of a supported engine.
   */
  public static function importChart(content:String, fileName:String = 'import.json', ?metaContent:String):Null<EngineImportResult>
  {
    var root:Null<Dynamic> = null;
    try
    {
      root = haxe.Json.parse(cleanJson(content));
    }
    catch (e:Dynamic)
    {
      trace('[FnfEngineImporter] Invalid JSON in $fileName: $e');
      return null;
    }

    var codename:Null<Dynamic> = codenameObject(root);
    if (codename != null) return importCodename(codename, fileName, metaContent);

    var song:Null<Dynamic> = songObject(root);
    if (song == null) return null;

    var baseName:String = fileNameWithoutExtension(fileName);
    var difficulty:String = difficultyFromFileName(baseName);
    var absoluteLanes:Bool = usesAbsoluteLanes(root, song);
    var songName:String = str(song.song) ?? str(song.songId) ?? songNameFromFileName(baseName);

    var sections:Array<Dynamic> = array(song.notes);
    var startBpm:Float = positive(num(song.bpm)) ?? Constants.DEFAULT_BPM;

    var timeChanges:Array<SongTimeChange> = [];
    var sectionStarts:Array<Float> = buildSectionStarts(sections, startBpm, timeChanges);

    var skippedEvents:Array<String> = [];
    var notes:Array<SongNoteData> = [];
    var events:Array<SongEventData> = [];
    var skippedTypes:Int = 0;

    // Notes, plus (in old charts) events stored as notes in a negative lane.
    for (index => section in sections)
    {
      var mustHit:Bool = section.mustHitSection == true;
      var sectionAlt:Bool = section.altAnim == true;

      for (raw in array(section.sectionNotes))
      {
        var note:Array<Dynamic> = array(raw);
        if (note.length < 2) continue;

        var time:Null<Float> = num(note[0]);

        // Psych 0.7+ can write events inside the notes: [time, "Name", value1, value2].
        if (time != null && Std.isOfType(note[1], String))
        {
          addPsychEvent(time, stringify(note[1]), stringify(note.length > 2 ? note[2] : ''), stringify(note.length > 3 ? note[3] : ''), events, skippedEvents,
            timeChanges);
          continue;
        }

        var lane:Null<Float> = num(note[1]);
        if (time == null || lane == null) continue;

        if (lane < 0)
        {
          readEventNote(note, time, events, skippedEvents, timeChanges);
          continue;
        }

        var kind:String = '';
        var typeValue:Dynamic = note.length > 3 ? note[3] : null;
        if (Std.isOfType(typeValue, String))
        {
          var type:String = StringTools.trim(cast typeValue);
          if (type == 'Alt Animation') kind = 'alt';
          else if (type != '')
            skippedTypes++;
        }
        else if (typeValue == true)
        {
          kind = 'alt'; // Psych 0.2 stored "alt" as a boolean.
        }
        else if (Std.isOfType(typeValue, Int) && typeValue != 0)
        {
          skippedTypes++; // Psych 0.2 numbered note types.
        }

        var laneIndex:Int = Std.int(lane) % (STRUMLINE_SIZE * 2);

        // Older charts: lanes 0-3 belong to the side that must hit the section, so swap them when that is the opponent.
        // `psych_v1` charts: the lanes are absolute (0-3 player, 4-7 opponent).
        var data:Int = laneIndex;
        if (!absoluteLanes && !mustHit) data = laneIndex >= STRUMLINE_SIZE ? laneIndex - STRUMLINE_SIZE : laneIndex + STRUMLINE_SIZE;

        // `altAnim` of a section applies to the character that sings it.
        var singsInThisSection:Bool = (data < STRUMLINE_SIZE) == mustHit;
        if (sectionAlt && singsInThisSection && kind == '') kind = 'alt';

        notes.push(new SongNoteData(time, data, Math.max(0, num(note.length > 2 ? note[2] : 0) ?? 0), kind));
      }
    }

    notes.sort((a, b) -> a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));

    // Events stored in the song (Psych 0.4 and later).
    readSongEvents(song, events, skippedEvents, timeChanges);

    // Camera focus follows who is singing, like Psych's own camera does.
    addCameraEvents(sections, sectionStarts, notes, events);
    events.sort((a, b) -> a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));

    var speed:Float = positive(num(song.speed)) ?? 1.0;
    var chart:SongChartData = new SongChartData([difficulty => speed], events, [difficulty => notes]);

    var metadata:SongMetadata = new SongMetadata(songName, Constants.DEFAULT_ARTIST, Constants.DEFAULT_CHARTER, Constants.DEFAULT_VARIATION);
    metadata.generatedBy = 'Chart Editor Import (FNF Engines)';
    metadata.timeChanges = timeChanges;
    metadata.playData.difficulties = [difficulty];
    metadata.playData.songVariations = [];
    metadata.playData.stage = convertStage(str(song.stage));
    metadata.playData.characters = new SongCharacterData(str(song.player1) ?? 'bf', str(song.gfVersion) ?? str(song.player3) ?? 'gf',
      str(song.player2) ?? 'dad');

    return {
      metadata: metadata,
      chart: chart,
      difficulty: difficulty,
      sourceFormat: 'Psych ' + detectFormat(root, song, sections) + (detectFormat(root, song, sections) == '0.6' ? ' / Kade' : ''),
      skippedEvents: skippedEvents,
      skippedNoteTypes: skippedTypes
    };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Structure
  // ---------------------------------------------------------------------------------------------------------------


  /**
   * `psych_v1` charts (Psych 0.7+/1.0, P-Slice) use absolute lanes. `psych_v1_convert` (a half-way format) and charts with no
   * `format` still use lanes relative to `mustHitSection`.
   */
  static function usesAbsoluteLanes(root:Dynamic, song:Dynamic):Bool
  {
    var format:Null<String> = str(Reflect.field(song, 'format')) ?? str(Reflect.field(root, 'format'));
    if (format == null) return false;
    var normalized:String = ~/[^a-z0-9]/g.replace(format.toLowerCase(), '');
    return StringTools.startsWith(normalized, 'psychv1') && normalized.indexOf('convert') < 0;
  }

  /**
   * The Codename Engine chart object (`strumLines`), at the root or inside `song`.
   */
  static function codenameObject(root:Null<Dynamic>):Null<Dynamic>
  {
    if (root == null || !Reflect.isObject(root)) return null;
    if (Std.isOfType(Reflect.field(root, 'strumLines'), Array)) return root;

    var wrapped:Null<Dynamic> = Reflect.field(root, 'song');
    if (wrapped != null && Reflect.isObject(wrapped) && !Std.isOfType(wrapped, String) && Std.isOfType(Reflect.field(wrapped, 'strumLines'), Array)) return wrapped;

    return null;
  }

  /**
   * Codename Engine: one file per difficulty, strumlines typed 0 opponent / 1 player / 2 girlfriend.
   */
  static function importCodename(chart:Dynamic, fileName:String, metaContent:Null<String>):Null<EngineImportResult>
  {
    var meta:Null<Dynamic> = null;
    if (metaContent != null)
    {
      try
      {
        meta = haxe.Json.parse(cleanJson(metaContent));
      }
      catch (e:Dynamic) {}
    }
    if (meta == null || !Reflect.isObject(meta)) meta = Reflect.field(chart, 'meta');
    if (meta == null || !Reflect.isObject(meta)) meta = {};

    var baseName:String = fileNameWithoutExtension(fileName);
    // Codename difficulties can have any name: the file name is the difficulty.
    var difficulty:String = baseName.toLowerCase();
    if (difficulty == '' || difficulty == 'import') difficulty = 'normal';

    var strumLines:Array<Dynamic> = array(chart.strumLines);
    var noteTypes:Array<Dynamic> = array(chart.noteTypes);
    var baseBpm:Float = positive(num(Reflect.field(meta, 'bpm'))) ?? Constants.DEFAULT_BPM;

    var notes:Array<SongNoteData> = [];
    var skippedEvents:Array<String> = [];
    var skippedTypes:Int = 0;
    var skippedGfNotes:Int = 0;

    function lineOfType(type:Int):Null<Dynamic>
    {
      for (line in strumLines)
        if (num(line.type) == type) return line;
      return null;
    }

    function characterOf(type:Int, fallback:String):String
    {
      var line:Null<Dynamic> = lineOfType(type);
      var characters:Array<Dynamic> = line == null ? [] : array(line.characters);
      return characters.length > 0 ? (str(characters[0]) ?? fallback) : fallback;
    }

    for (line in strumLines)
    {
      var type:Int = Std.int(num(line.type) ?? 0);
      if (type == 2)
      {
        skippedGfNotes += array(line.notes).length;
        continue;
      }

      var baseLane:Int = type == 1 ? 0 : STRUMLINE_SIZE; // Player 0-3, opponent 4-7.
      for (raw in array(line.notes))
      {
        var time:Null<Float> = num(raw.time);
        if (time == null) continue;

        var id:Int = Std.int(num(raw.id) ?? 0);
        var lane:Int = baseLane + (((id % STRUMLINE_SIZE) + STRUMLINE_SIZE) % STRUMLINE_SIZE);
        var noteType:Int = Std.int(num(raw.type) ?? 0);
        if (noteType > 0) skippedTypes++;

        notes.push(new SongNoteData(time, lane, Math.max(0, num(raw.sLen) ?? 0), ''));
      }
    }
    notes.sort((a, b) -> a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
    if (skippedGfNotes > 0) skippedEvents.push('Girlfriend strumline ($skippedGfNotes notes)');

    var events:Array<SongEventData> = [];
    var timeChanges:Array<SongTimeChange> = [new SongTimeChange(0, baseBpm)];
    var bpmChanges:Array<{time:Float, bpm:Float}> = [];

    for (raw in array(chart.events))
    {
      var name:String = (str(raw.name) ?? '').toLowerCase();
      var params:Array<Dynamic> = array(raw.params);
      var time:Float = num(raw.time) ?? 0;

      switch (name)
      {
        case 'camera movement':
          // The parameter is the INDEX of the target strumline: look up what kind it is.
          var index:Int = Std.int(num(params[0]) ?? 0);
          var target:Null<Dynamic> = index >= 0 && index < strumLines.length ? strumLines[index] : null;
          var kind:Int = target != null ? Std.int(num(target.type) ?? 0) : (index == 1 ? 1 : 0);
          events.push(new SongEventData(time, 'FocusCamera', {char: kind == 1 ? 0 : (kind == 2 ? 2 : 1)}));

        case 'camera zoom':
          // [tween?, zoom, camera, duration, ease, type, mode]
          var zoom:Float = num(params[1]) ?? 1.4;
          events.push(new SongEventData(time, 'ZoomCamera', {zoom: zoom, duration: 4.0, mode: str(params[6]) == 'stage' ? 'stage' : 'direct', ease: 'expoInOut'}));

        case 'add camera zoom':
          events.push(new SongEventData(time, 'ZoomCamera', {
            zoom: Math.round((1.0 + (num(params[0]) ?? 0.015)) * 10000) / 10000,
            duration: 4.0,
            mode: 'stage',
            ease: 'expoInOut'
          }));

        case 'bpm change':
          var bpm:Null<Float> = positive(num(params[0]));
          if (bpm != null) bpmChanges.push({time: time, bpm: bpm});

        default:
          var original:String = str(raw.name) ?? '';
          if (original != '' && skippedEvents.indexOf(original) == -1) skippedEvents.push(original);
      }
    }

    bpmChanges.sort((a, b) -> a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
    for (change in bpmChanges)
      timeChanges.push(new SongTimeChange(change.time, change.bpm));
    events.sort((a, b) -> a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));

    var songName:String = str(Reflect.field(meta, 'displayName')) ?? str(Reflect.field(meta, 'name')) ?? songNameFromFileName(baseName);
    var speed:Float = positive(num(chart.scrollSpeed)) ?? 1.0;

    var metadata:SongMetadata = new SongMetadata(songName, Constants.DEFAULT_ARTIST, Constants.DEFAULT_CHARTER, Constants.DEFAULT_VARIATION);
    metadata.generatedBy = 'Chart Editor Import (FNF Engines)';
    metadata.timeChanges = timeChanges;
    metadata.playData.difficulties = [difficulty];
    metadata.playData.songVariations = [];
    metadata.playData.stage = convertStage(str(chart.stage));
    metadata.playData.characters = new SongCharacterData(characterOf(1, 'bf'), characterOf(2, 'gf'), characterOf(0, 'dad'));

    return {
      metadata: metadata,
      chart: new SongChartData([difficulty => speed], events, [difficulty => notes]),
      difficulty: difficulty,
      sourceFormat: 'Codename',
      skippedEvents: skippedEvents,
      skippedNoteTypes: skippedTypes
    };
  }

  /**
   * The difficulties a Codename Engine `meta.json` lists, if any.
   */
  public static function codenameDifficulties(metaContent:String):Array<String>
  {
    try
    {
      var meta:Dynamic = haxe.Json.parse(cleanJson(metaContent));
      var result:Array<String> = [];
      for (d in array(Reflect.field(meta, 'difficulties')))
      {
        var name:Null<String> = str(d);
        if (name != null) result.push(name.toLowerCase());
      }
      return result;
    }
    catch (e:Dynamic)
    {
      return [];
    }
  }

  /**
   * The object holding the chart: `song` in older versions, the root itself in `psych_v1`.
   */
  static function songObject(root:Null<Dynamic>):Null<Dynamic>
  {
    if (root == null || !Reflect.isObject(root)) return null;

    var wrapped:Null<Dynamic> = Reflect.field(root, 'song');
    if (wrapped != null && Reflect.isObject(wrapped) && !Std.isOfType(wrapped, String) && Std.isOfType(Reflect.field(wrapped, 'notes'), Array)) return wrapped;

    // Psych 1.0 (and a few converters) put everything at the root.
    if (Std.isOfType(Reflect.field(root, 'notes'), Array)) return root;

    return null;
  }


  /**
   * Psych 0.6 and 0.7 keep the events of a song in a separate `events.json` next to the charts. Read them so they can
   * be added to a chart.
   * @param timeChanges The BPM changes of the chart the events go with (durations depend on the BPM).
   * @return The events and the names of the ones that have no V-Slice equivalent, or `null` if it isn't a Psych file.
   */
  public static function importEventsFile(content:String, timeChanges:Array<SongTimeChange>):Null<{events:Array<SongEventData>, skipped:Array<String>}>
  {
    var root:Null<Dynamic> = null;
    try
    {
      root = haxe.Json.parse(cleanJson(content));
    }
    catch (e:Dynamic)
    {
      return null;
    }

    var song:Null<Dynamic> = songObject(root);
    if (song == null) return null;

    var events:Array<SongEventData> = [];
    var skipped:Array<String> = [];
    readSongEvents(song, events, skipped, timeChanges);

    // Very old files keep events as notes of a negative lane.
    for (section in array(song.notes))
    {
      for (raw in array(section.sectionNotes))
      {
        var note:Array<Dynamic> = array(raw);
        var time:Null<Float> = note.length > 1 ? num(note[0]) : null;
        var lane:Null<Float> = note.length > 1 ? num(note[1]) : null;
        if (time != null && lane != null && lane < 0) readEventNote(note, time, events, skipped, timeChanges);
      }
    }

    events.sort((a, b) -> a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
    return {events: events, skipped: skipped};
  }

  static function readSongEvents(song:Dynamic, events:Array<SongEventData>, skippedEvents:Array<String>, timeChanges:Array<SongTimeChange>):Void
  {
    for (entry in array(song.events))
    {
      var group:Array<Dynamic> = array(entry);
      if (group.length < 2) continue;
      var time:Null<Float> = num(group[0]);
      if (time == null) continue;

      for (rawEvent in array(group[1]))
      {
        var event:Array<Dynamic> = array(rawEvent);
        if (event.length < 1) continue;
        addPsychEvent(time, str(event[0]) ?? '', stringify(event.length > 1 ? event[1] : ''), stringify(event.length > 2 ? event[2] : ''), events,
          skippedEvents, timeChanges);
      }
    }
  }

  /**
   * Which generation of Psych wrote this chart.
   * - `1.0`: `"format": "psych_v1"`, or everything at the root with no `song` wrapper.
   * - `0.7`: sections with `sectionBeats` (and `gfSection`).
   * - `0.6`: sections with `lengthInSteps`, or anything older.
   */
  static function detectFormat(root:Null<Dynamic>, song:Dynamic, sections:Array<Dynamic>):String
  {
    var format:Null<String> = str(Reflect.field(root, 'format')) ?? str(Reflect.field(song, 'format'));
    if (format != null && StringTools.startsWith(format, 'psych_v')) return '1.0';
    if (song == root) return '1.0';

    for (section in sections)
    {
      if (Reflect.hasField(section, 'sectionBeats')) return '0.7';
    }
    return '0.6';
  }

  /**
   * Psych reads charts leniently, so do the same: drop a byte order mark and whatever is after the last `}`
   * (0.6 charts saved by some tools end in padding or null characters).
   */
  static function cleanJson(content:String):String
  {
    var text:String = content;
    if (text.length > 0 && text.charCodeAt(0) == 0xFEFF) text = text.substr(1);
    var end:Int = text.lastIndexOf('}');
    if (end >= 0 && end < text.length - 1) text = text.substr(0, end + 1);
    return StringTools.trim(text);
  }

  /**
   * When each section starts, in ms. Also fills `timeChanges` with the BPM changes, at the exact start of the section.
   */
  static function buildSectionStarts(sections:Array<Dynamic>, startBpm:Float, timeChanges:Array<SongTimeChange>):Array<Float>
  {
    var starts:Array<Float> = [];
    var bpm:Float = startBpm;
    var time:Float = 0;

    timeChanges.push(new SongTimeChange(0, bpm));

    for (index => section in sections)
    {
      starts.push(time);

      // A BPM change on the very first section just sets the song's starting BPM.
      if (section.changeBPM == true)
      {
        var newBpm:Null<Float> = positive(num(section.bpm));
        if (newBpm != null && newBpm != bpm)
        {
          bpm = newBpm;
          if (index == 0 && time == 0) timeChanges[0] = new SongTimeChange(0, bpm);
          else
            timeChanges.push(new SongTimeChange(time, bpm));
        }
      }

      time += sectionBeats(section) * 60000.0 / bpm;
    }

    return starts;
  }

  /**
   * How many beats a section lasts: `sectionBeats` (0.7+), or `lengthInSteps` / 4 (older charts).
   */
  static function sectionBeats(section:Dynamic):Float
  {
    var beats:Null<Float> = positive(num(section.sectionBeats));
    if (beats != null) return beats;

    var steps:Null<Float> = positive(num(section.lengthInSteps));
    if (steps != null) return steps / 4.0;

    return DEFAULT_SECTION_BEATS;
  }

  static function bpmAt(time:Float, timeChanges:Array<SongTimeChange>):Float
  {
    var bpm:Float = timeChanges.length > 0 ? timeChanges[0].bpm : Constants.DEFAULT_BPM;
    for (change in timeChanges)
    {
      if (change.timeStamp <= time) bpm = change.bpm;
    }
    return bpm;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Camera
  // ---------------------------------------------------------------------------------------------------------------

  /**
   * Psych points the camera at the section's singer: girlfriend for `gfSection`, otherwise the one that must hit.
   * V-Slice does it with events, so one is added each time the target changes.
   */
  static function addCameraEvents(sections:Array<Dynamic>, starts:Array<Float>, notes:Array<SongNoteData>, events:Array<SongEventData>):Void
  {
    var last:Int = -2;
    for (index => section in sections)
    {
      var target:Int = section.gfSection == true ? 2 : (section.mustHitSection == true ? 0 : 1);
      if (target == last) continue;

      // Skip the changes of empty stretches at the start, but always set the camera at the very beginning.
      if (index > 0 && array(section.sectionNotes).length == 0) continue;

      last = target;
      events.push(new SongEventData(starts[index], 'FocusCamera', {char: target}));
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------------------------------------------

  /**
   * An old-style event: `[time, -1, ...]`, either `[time, -1, [[name, v1, v2]]]` or `[time, -1, name, v1, v2]`.
   */
  static function readEventNote(note:Array<Dynamic>, time:Float, events:Array<SongEventData>, skipped:Array<String>, timeChanges:Array<SongTimeChange>):Void
  {
    if (note.length < 3) return;

    if (Std.isOfType(note[2], Array))
    {
      for (rawEvent in array(note[2]))
      {
        var event:Array<Dynamic> = array(rawEvent);
        if (event.length < 1) continue;
        addPsychEvent(time, str(event[0]) ?? '', stringify(event.length > 1 ? event[1] : ''), stringify(event.length > 2 ? event[2] : ''), events, skipped,
          timeChanges);
      }
    }
    else
    {
      addPsychEvent(time, str(note[2]) ?? '', stringify(note.length > 3 ? note[3] : ''), stringify(note.length > 4 ? note[4] : ''), events, skipped,
        timeChanges);
    }
  }

  /**
   * Convert one Psych event to a V-Slice event, or remember its name if there's nothing equivalent.
   */
  static function addPsychEvent(time:Float, name:String, value1:String, value2:String, events:Array<SongEventData>, skipped:Array<String>,
      timeChanges:Array<SongTimeChange>):Void
  {
    switch (name)
    {
      case 'Camera Follow Pos':
        var x:Null<Float> = Std.parseFloat(value1);
        var y:Null<Float> = Std.parseFloat(value2);
        // Empty values mean "go back to following the characters", which the section events already do.
        if (x == null || y == null || Math.isNaN(x) || Math.isNaN(y)) return;
        events.push(new SongEventData(time, 'FocusCamera', {char: -1, x: x, y: y}));

      case 'Play Animation':
        if (value1 == '') return;
        events.push(new SongEventData(time, 'PlayAnimation', {target: animationTarget(value2), anim: value1, force: true}));

      case 'Hey!':
        var who:String = value1.toLowerCase();
        if (who != 'gf' && who != 'girlfriend') events.push(new SongEventData(time, 'PlayAnimation', {target: 'bf', anim: 'hey', force: true}));
        if (who != 'bf' && who != 'boyfriend') events.push(new SongEventData(time, 'PlayAnimation', {target: 'gf', anim: 'cheer', force: true}));

      case 'Change Scroll Speed':
        var multiplier:Float = Std.parseFloat(value1);
        if (Math.isNaN(multiplier) || multiplier <= 0) return;
        var seconds:Float = Std.parseFloat(value2);
        if (Math.isNaN(seconds) || seconds < 0) seconds = 0;
        // Psych gives the duration in seconds, V-Slice in steps.
        var stepMs:Float = 60000.0 / bpmAt(time, timeChanges) / 4.0;
        events.push(new SongEventData(time, 'ScrollSpeed', {
          scroll: multiplier,
          duration: seconds * 1000.0 / stepMs,
          ease: 'linear',
          strumline: 'both',
          absolute: false
        }));

      default:
        var key:String = ~/[^a-z]/g.replace(name.toLowerCase(), '');
        if (key == 'focuscamera')
        {
          var target:Null<Int> = Std.parseInt(value1);
          events.push(new SongEventData(time, 'FocusCamera', {char: target == 0 ? 0 : (target == 2 ? 2 : 1)}));
        }
        else if (key.indexOf('zoom') >= 0)
        {
          // "Add Camera Zoom" adds to the zoom (0.015 by default); other zoom events hold the zoom itself.
          var amount:Float = Std.parseFloat(value1);
          var zoom:Float = key == 'addcamerazoom' ? 1.0 + (Math.isNaN(amount) ? 0.015 : amount) : (Math.isNaN(amount) ? 1.0 : amount);
          events.push(new SongEventData(time, 'ZoomCamera', {zoom: Math.round(zoom * 10000) / 10000, duration: 4.0, mode: 'stage', ease: 'expoInOut'}));
        }
        else if (name != '' && skipped.indexOf(name) == -1)
          skipped.push(name);
    }
  }

  /**
   * Psych names the character with `bf`/`gf`/`dad` or a number (0 dad, 1 bf, 2 gf).
   */
  static function animationTarget(value:String):String
  {
    switch (value.toLowerCase())
    {
      case 'bf' | 'boyfriend':
        return 'bf';
      case 'gf' | 'girlfriend':
        return 'gf';
      case 'dad':
        return 'dad';
      default:
        return switch (Std.parseInt(value))
        {
          case 1: 'bf';
          case 2: 'gf';
          default: 'dad';
        }
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Names
  // ---------------------------------------------------------------------------------------------------------------

  static function convertStage(stage:Null<String>):String
  {
    if (stage == null || stage == '') return 'mainStage';
    return STAGE_NAMES.get(stage) ?? stage;
  }

  static function fileNameWithoutExtension(fileName:String):String
  {
    var name:String = StringTools.replace(fileName, '\\', '/');
    name = name.substr(name.lastIndexOf('/') + 1);
    var dot:Int = name.lastIndexOf('.');
    return dot > 0 ? name.substr(0, dot) : name;
  }

  /**
   * Psych names difficulty files `song-easy.json`, `song-hard.json`, and plain `song.json` for normal.
   */
  static function difficultyFromFileName(baseName:String):String
  {
    var dash:Int = baseName.lastIndexOf('-');
    if (dash > 0)
    {
      var suffix:String = baseName.substr(dash + 1).toLowerCase();
      if (suffix == 'easy' || suffix == 'hard' || suffix == 'erect' || suffix == 'nightmare') return suffix;
    }
    return 'normal';
  }

  static function songNameFromFileName(baseName:String):String
  {
    var dash:Int = baseName.lastIndexOf('-');
    var name:String = baseName;
    if (dash > 0 && difficultyFromFileName(baseName) != 'normal') name = baseName.substr(0, dash);
    return name == '' ? 'Import' : name;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Reading dynamic JSON safely
  // ---------------------------------------------------------------------------------------------------------------

  static function array(value:Null<Dynamic>):Array<Dynamic>
  {
    return Std.isOfType(value, Array) ? cast value : [];
  }

  static function num(value:Null<Dynamic>):Null<Float>
  {
    if (Std.isOfType(value, Float) || Std.isOfType(value, Int))
    {
      var f:Float = cast value;
      return (Math.isNaN(f) || !Math.isFinite(f)) ? null : f;
    }

    if (Std.isOfType(value, String))
    {
      var parsed:Float = Std.parseFloat(cast value);
      return Math.isNaN(parsed) ? null : parsed;
    }

    return null;
  }

  static function positive(value:Null<Float>):Null<Float>
  {
    return (value != null && value > 0) ? value : null;
  }

  static function str(value:Null<Dynamic>):Null<String>
  {
    if (!Std.isOfType(value, String)) return null;
    var text:String = StringTools.trim(cast value);
    return text == '' ? null : text;
  }

  /**
   * Event values are strings in Psych, but old charts may hold numbers or booleans.
   */
  static function stringify(value:Null<Dynamic>):String
  {
    if (value == null) return '';
    return Std.isOfType(value, String) ? StringTools.trim(cast value) : Std.string(value);
  }
}
