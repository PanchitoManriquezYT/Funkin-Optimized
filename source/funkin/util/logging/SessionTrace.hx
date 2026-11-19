package funkin.util.logging;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * A tiny breadcrumb log that is written to disk immediately, line by line.
 *
 * When the app is killed by the system (out of memory, a native crash) no error and no crash log exist.
 * The last line of `logs/trace.log` (in the data folder) then tells where it stopped, and how much memory was in use.
 * The previous session's file is kept as `logs/trace-previous.log`.
 */
class SessionTrace
{
  static inline var FILE:String = 'logs/trace.log';
  static inline var PREVIOUS:String = 'logs/trace-previous.log';

  static var started:Bool = false;
  static var disabled:Bool = false;

  /**
   * Write one line: the time, the memory in use, and what is happening.
   */
  public static function mark(what:String):Void
  {
    #if (sys && !web)
    if (disabled) return;
    try
    {
      if (!started)
      {
        started = true;
        if (!FileSystem.exists('logs')) FileSystem.createDirectory('logs');
        if (FileSystem.exists(FILE)) File.copy(FILE, PREVIOUS);
        File.saveContent(FILE, 'Trace started ${Date.now().toString()}\n');
      }

      var memoryMb:Int = Std.int(openfl.system.System.totalMemory / 1048576);
      var out = File.append(FILE, false);
      out.writeString('${Std.int(haxe.Timer.stamp() * 1000) % 100000000}ms | ${memoryMb}MB | $what\n');
      out.close();
    }
    catch (e:Dynamic)
    {
      disabled = true;
    }
    #end
  }
}
