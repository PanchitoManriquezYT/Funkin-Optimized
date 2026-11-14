package funkin.ui.options;

/**
 * Options > Graphics: the settings that trade looks for speed or memory.
 * It is a preferences page with its own list.
 */
class GraphicsMenu extends PreferencesMenu
{
  override function createPrefItems():Void
  {
    createPrefItemCheckbox('Low Quality',
      'When enabled, optional extras are dropped to run faster: no shaders, no antialiasing and no note splashes. Overrides the two settings below.',
      function(value:Bool):Void
      {
        Preferences.lowQuality = value;
      }, Preferences.lowQuality);

    createPrefItemCheckbox('Anti-Aliasing', 'When enabled, sprites are smoothed. Disable for sharper (and slightly faster) graphics.', function(value:Bool):Void
    {
      Preferences.antialiasing = value;
    }, Preferences.antialiasing);

    createPrefItemCheckbox('Shaders', 'When enabled, visual shader effects (stage and character shaders) are applied. Disable for better performance.',
      function(value:Bool):Void
      {
        Preferences.shaders = value;
      }, Preferences.shaders);

    createPrefItemCheckbox('CPU Caching',
      'When enabled, textures stay in RAM after loading. Disable to save memory on weak devices (takes effect on the next song or menu you load).',
      function(value:Bool):Void
      {
        Preferences.cpuCaching = value;
      }, Preferences.cpuCaching);
  }
}
