/*
 *      Copyright (C) 2005-2015 Team Kodi
 *      http://kodi.tv
 *
 *  This Program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2, or (at your option)
 *  any later version.
 *
 *  This Program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with Kodi; see the file COPYING.  If not, see
 *  <http://www.gnu.org/licenses/>.
 *
 */

#if defined(TARGET_DARWIN_OSX)

#include "WinSystemOSX.h"

#include "ServiceBroker.h"
#include "Application.h"
#include "guilib/DispResource.h"
#include "guilib/GUIWindowManager.h"
#include "settings/Settings.h"
#include "settings/DisplaySettings.h"
#include "messaging/ApplicationMessenger.h"
#include "cores/VideoPlayer/DVDCodecs/DVDFactoryCodec.h"
#include "cores/VideoPlayer/DVDCodecs/Video/VTB.h"
#include "cores/VideoPlayer/VideoRenderers/RenderFactory.h"
#include "cores/VideoPlayer/VideoRenderers/LinuxRendererGL.h"
#include "cores/VideoPlayer/VideoRenderers/HwDecRender/RendererVTBGL.h"
#include "utils/log.h"
#include "utils/StringUtils.h"
#include "platform/darwin/osx/XBMCHelper.h"
#include "utils/SystemInfo.h"
#include "platform/darwin/DictionaryUtils.h"
#include "platform/darwin/DarwinUtils.h"
#include "platform/darwin/osx/CocoaInterface.h"
#include "platform/darwin/osx/OSXTextInputResponder.h"
#include "platform/darwin/osx/OSXGLView.h"
#include "platform/darwin/osx/OSXGLWindow.h"
#include "OSScreenSaverOSX.h"

#import <Cocoa/Cocoa.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>


using namespace KODI::WINDOWING;

//------------------------------------------------------------------------------------------
#define MAX_DISPLAYS 32

//---------------------------------------------------------------------------------
CGDirectDisplayID GetDisplayID(int screen_index)
{
  CGDirectDisplayID displayArray[MAX_DISPLAYS];
  CGDisplayCount    numDisplays;

  // Get the list of displays.
  CGGetActiveDisplayList(MAX_DISPLAYS, displayArray, &numDisplays);
  return displayArray[screen_index];
}

CGDirectDisplayID GetDisplayIDFromScreen(NSScreen *screen)
{
  NSDictionary* screenInfo = [screen deviceDescription];
  NSNumber* screenID = [screenInfo objectForKey:@"NSScreenNumber"];

  return (CGDirectDisplayID)[screenID longValue];
}

size_t DisplayBitsPerPixelForMode(CGDisplayModeRef mode)
{
  size_t bitsPerPixel = 0;

  CFStringRef pixEnc = CGDisplayModeCopyPixelEncoding(mode);
  if(CFStringCompare(pixEnc, CFSTR(IO32BitDirectPixels), kCFCompareCaseInsensitive) == kCFCompareEqualTo)
  {
    bitsPerPixel = 32;
  }
  else if(CFStringCompare(pixEnc, CFSTR(IO16BitDirectPixels), kCFCompareCaseInsensitive) == kCFCompareEqualTo)
  {
    bitsPerPixel = 16;
  }
  else if(CFStringCompare(pixEnc, CFSTR(IO8BitIndexedPixels), kCFCompareCaseInsensitive) == kCFCompareEqualTo)
  {
    bitsPerPixel = 8;
  }

  CFRelease(pixEnc);

  return bitsPerPixel;
}

// mimic former behavior of deprecated CGDisplayBestModeForParameters
CGDisplayModeRef BestMatchForMode(CGDirectDisplayID display, size_t bitsPerPixel, size_t width, size_t height, boolean_t &match)
{
  // Get a copy of the current display mode
  CGDisplayModeRef displayMode = CGDisplayCopyDisplayMode(kCGDirectMainDisplay);

  // Loop through all display modes to determine the closest match.
  // CGDisplayBestModeForParameters is deprecated on 10.6 so we will emulate it's behavior
  // Try to find a mode with the requested depth and equal or greater dimensions first.
  // If no match is found, try to find a mode with greater depth and same or greater dimensions.
  // If still no match is found, just use the current mode.
  CFArrayRef allModes = CGDisplayCopyAllDisplayModes(kCGDirectMainDisplay, NULL);
  for(int i = 0; i < CFArrayGetCount(allModes); i++)	{
    CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);

    if(DisplayBitsPerPixelForMode(mode) != bitsPerPixel)
      continue;

    if((CGDisplayModeGetWidth(mode) == width) && (CGDisplayModeGetHeight(mode) == height))
    {
      CGDisplayModeRelease(displayMode); // rlease the copy we got before ...
      displayMode = mode;
      match = true;
      break;
    }
  }

  // No depth match was found
  if(!match)
  {
    for(int i = 0; i < CFArrayGetCount(allModes); i++)
    {
      CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
      if(DisplayBitsPerPixelForMode(mode) >= bitsPerPixel)
        continue;

      if((CGDisplayModeGetWidth(mode) == width) && (CGDisplayModeGetHeight(mode) == height))
      {
        displayMode = mode;
        match = true;
        break;
      }
    }
  }

  CFRelease(allModes);

  return displayMode;
}

int GetDisplayIndex(CGDirectDisplayID display)
{
  CGDirectDisplayID displayArray[MAX_DISPLAYS];
  CGDisplayCount    numDisplays;
  
  // Get the list of displays.
  CGGetActiveDisplayList(MAX_DISPLAYS, displayArray, &numDisplays);
  while (numDisplays > 0)
  {
    if (display == displayArray[--numDisplays])
      return numDisplays;
  }
  return -1;
}

NSString* screenNameForDisplay(CGDirectDisplayID displayID)
{
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  NSString *screenName = nil;

  // IODisplayCreateInfoDictionary leaks IOCFUnserializeparse, nothing we can do about it.
  NSDictionary *deviceInfo = (NSDictionary *)IODisplayCreateInfoDictionary(CGDisplayIOServicePort(displayID), kIODisplayOnlyPreferredName);
  NSDictionary *localizedNames = [deviceInfo objectForKey:[NSString stringWithUTF8String:kDisplayProductName]];

  if ([localizedNames count] > 0) {
      screenName = [[localizedNames objectForKey:[[localizedNames allKeys] objectAtIndex:0]] retain];
  }

  [deviceInfo release];
  [pool release];

  return [screenName autorelease];
}

// try to find mode that matches the desired size, refreshrate
// non interlaced, nonstretched, safe for hardware
CGDisplayModeRef GetMode(int width, int height, double refreshrate, int screenIdx)
{
  if ( screenIdx >= (signed)[[NSScreen screens] count])
    return NULL;

  Boolean stretched;
  Boolean interlaced;
  Boolean safeForHardware;
  Boolean televisionoutput;
  int w, h, bitsperpixel;
  double rate;
  RESOLUTION_INFO res;

  CLog::Log(LOGDEBUG, "GetMode looking for suitable mode with %d x %d @ %f Hz on display %d\n", width, height, refreshrate, screenIdx);

  CFArrayRef displayModes = CGDisplayCopyAllDisplayModes(GetDisplayID(screenIdx), nullptr);

  if (NULL == displayModes)
  {
    CLog::Log(LOGERROR, "GetMode - no displaymodes found!");
    return NULL;
  }

  for (int i=0; i < CFArrayGetCount(displayModes); ++i)
  {
    CGDisplayModeRef displayMode = (CGDisplayModeRef)CFArrayGetValueAtIndex(displayModes, i);
    uint32_t flags = CGDisplayModeGetIOFlags(displayMode);
    stretched = flags & kDisplayModeStretchedFlag ? true : false;
    interlaced = flags & kDisplayModeInterlacedFlag ? true : false;
    bitsperpixel = DisplayBitsPerPixelForMode(displayMode);
    safeForHardware = flags & kDisplayModeSafetyFlags ? true : false;
    televisionoutput = flags & kDisplayModeTelevisionFlag ? true : false;
    w = CGDisplayModeGetWidth(displayMode);
    h = CGDisplayModeGetHeight(displayMode);
    rate = CGDisplayModeGetRefreshRate(displayMode);


    if ((bitsperpixel == 32)      &&
        (safeForHardware == YES)  &&
        (stretched == NO)         &&
        (interlaced == NO)        &&
        (w == width)              &&
        (h == height)             &&
        (rate == refreshrate || rate == 0))
    {
      CLog::Log(LOGDEBUG, "GetMode found a match!");
      return displayMode;
    }
  }

  CFRelease(displayModes);
  CLog::Log(LOGERROR, "GetMode - no match found!");
  return NULL;
}
//---------------------------------------------------------------------------------
static void DisplayReconfigured(CGDirectDisplayID display,
                                CGDisplayChangeSummaryFlags flags, void* userData)
{
  CWinSystemOSX *winsys = (CWinSystemOSX*)userData;
  if (!winsys)
    return;

  CLog::Log(LOGDEBUG, "CWinSystemOSX::DisplayReconfigured with flags %d", flags);

  // we fire the callbacks on start of configuration
  // or when the mode set was finished
  // or when we are called with flags == 0 (which is undocumented but seems to happen
  // on some macs - we treat it as device reset)

  // first check if we need to call OnLostDevice
  if (flags & kCGDisplayBeginConfigurationFlag)
  {
    // pre/post-reconfiguration changes
    RESOLUTION res = g_graphicsContext.GetVideoResolution();
    if (res == RES_INVALID)
      return;

    NSScreen* pScreen = nil;
    unsigned int screenIdx = CDisplaySettings::GetInstance().GetResolutionInfo(res).iScreen;

    if ( screenIdx < [[NSScreen screens] count] )
    {
      pScreen = [[NSScreen screens] objectAtIndex:screenIdx];
    }

    // kCGDisplayBeginConfigurationFlag is only fired while the screen is still
    // valid
    if (pScreen)
    {
      CGDirectDisplayID xbmc_display = GetDisplayIDFromScreen(pScreen);
      if (xbmc_display == display)
      {
        // we only respond to changes on the display we are running on.
        winsys->AnnounceOnLostDevice();
        winsys->StartLostDeviceTimer();
      }
    }
  }
  else // the else case checks if we need to call OnResetDevice
  {
    // we fire if kCGDisplaySetModeFlag is set or if flags == 0
    // (which is undocumented but seems to happen
    // on some macs - we treat it as device reset)
    // we also don't check the screen here as we might not even have
    // one anymore (e.x. when tv is turned off)
    if (flags & kCGDisplaySetModeFlag || flags == 0)
    {
      winsys->StopLostDeviceTimer(); // no need to timeout - we've got the callback
      winsys->HandleOnResetDevice();
    }
  }

  if ((flags & kCGDisplayAddFlag) || (flags & kCGDisplayRemoveFlag))
    winsys->UpdateResolutions();
}//---------------------------------------------------------------------------------
//---------------------------------------------------------------------------------
CWinSystemOSX::CWinSystemOSX() : CWinSystemBase(), m_lostDeviceTimer(this)
{
  m_eWindowSystem = WINDOW_SYSTEM_OSX;
  m_appWindow  = NULL;
  m_glView     = NULL;
  m_lastDisplayNr = -1;
  m_movedToOtherScreen = false;
  m_refreshRate = 0.0;
  m_delayDispReset = false;
  m_fullscreenWillToggle = false;
  m_lastX = 0;
  m_lastY = 0;
}

CWinSystemOSX::~CWinSystemOSX()
{
}

// if there was a devicelost callback but no device reset for 3 secs
// a timeout fires the reset callback (for ensuring that e.x. AE isn't stuck)
#define LOST_DEVICE_TIMEOUT_MS 3000

void CWinSystemOSX::StartLostDeviceTimer()
{
  if (m_lostDeviceTimer.IsRunning())
    m_lostDeviceTimer.Restart();
  else
    m_lostDeviceTimer.Start(LOST_DEVICE_TIMEOUT_MS, false);
}

void CWinSystemOSX::StopLostDeviceTimer()
{
  m_lostDeviceTimer.Stop();
}

void CWinSystemOSX::OnTimeout()
{
  HandleOnResetDevice();
}

bool CWinSystemOSX::InitWindowSystem()
{
  if (!CWinSystemBase::InitWindowSystem())
    return false;

  CGDisplayRegisterReconfigurationCallback(DisplayReconfigured, (void*)this);

  return true;
}

bool CWinSystemOSX::DestroyWindowSystem()
{
  //printf("CWinSystemOSX::DestroyWindowSystem\n");
  CGDisplayRemoveReconfigurationCallback(DisplayReconfigured, (void*)this);

  DestroyWindowInternal();
  
  if (m_glView)
  {
    // normally, this should happen here but we are racing internal object destructors
    // that make GL calls. They crash if the GLView is released.
    //[(OSXGLView*)m_glView release];
    m_glView = NULL;
  }
  
  return true;
}

bool CWinSystemOSX::DestroyWindowInternal()
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  // set this 1st, we should really mutex protext m_appWindow in this class
  m_bWindowCreated = false;
  if (m_appWindow)
  {
    NSWindow *oldAppWindow = (NSWindow*)m_appWindow;
    m_appWindow = NULL;
    [oldAppWindow setContentView:nil];
    [oldAppWindow release];
  }

  [pool release];

  return true;
}

bool CWinSystemOSX::DestroyWindow()
{
  // when using native fullscreen
  // we never destroy the window
  // we reuse it ...
  return true;
}

void CWinSystemOSX::UpdateResolutions()
{
  CWinSystemBase::UpdateResolutions();

  // Add desktop resolution
  int w, h;
  double fps;

  // first screen goes into the current desktop mode
  GetScreenResolution(&w, &h, &fps, 0);
  UpdateDesktopResolution(CDisplaySettings::GetInstance().GetResolutionInfo(RES_DESKTOP), 0, w, h, fps);

  // see resolution.h enum RESOLUTION for how the resolutions
  // have to appear in the resolution info vector in CDisplaySettings
  // add the desktop resolutions of the other screens
  for(int i = 1; i < GetNumScreens(); i++)
  {
    RESOLUTION_INFO res;
    // get current resolution of screen i
    GetScreenResolution(&w, &h, &fps, i);
    UpdateDesktopResolution(res, i, w, h, fps);
    CDisplaySettings::GetInstance().AddResolutionInfo(res);
  }

  // now just fill in the possible reolutions for the attached screens
  // and push to the resolution info vector
  FillInVideoModes();
}

void CWinSystemOSX::GetScreenResolution(int* w, int* h, double* fps, int screenIdx)
{
  // Figure out the screen size. (default to main screen)
  if (screenIdx >= GetNumScreens())
    return;

  CGDirectDisplayID display_id = (CGDirectDisplayID)GetDisplayID(screenIdx);

  if (m_appWindow)
    display_id = GetDisplayIDFromScreen( [(NSWindow *)m_appWindow screen] );
  CGDisplayModeRef mode  = CGDisplayCopyDisplayMode(display_id);
  *w = CGDisplayModeGetWidth(mode);
  *h = CGDisplayModeGetHeight(mode);
  *fps = CGDisplayModeGetRefreshRate(mode);
  CGDisplayModeRelease(mode);
  if ((int)*fps == 0)
  {
    // NOTE: The refresh rate will be REPORTED AS 0 for many DVI and notebook displays.
    *fps = 60.0;
  }
}

void CWinSystemOSX::EnableVSync(bool enable)
{
  // OpenGL Flush synchronised with vertical retrace
  GLint swapInterval = enable ? 1 : 0;
  [[NSOpenGLContext currentContext] setValues:&swapInterval forParameter:NSOpenGLCPSwapInterval];
}

bool CWinSystemOSX::SwitchToVideoMode(int width, int height, double refreshrate, int screenIdx)
{
  // SwitchToVideoMode will not return until the display has actually switched over.
  // This can take several seconds.
  if( screenIdx >= GetNumScreens())
    return false;

  boolean_t match = false;
  CGDisplayModeRef dispMode = NULL;
  // Figure out the screen size. (default to main screen)
  CGDirectDisplayID display_id = GetDisplayID(screenIdx);

  // find mode that matches the desired size, refreshrate
  // non interlaced, nonstretched, safe for hardware
  dispMode = GetMode(width, height, refreshrate, screenIdx);

  //not found - fallback to bestemdeforparameters
  if (!dispMode)
  {
    dispMode = BestMatchForMode(display_id, 32, width, height, match);

    if (!match)
      dispMode = BestMatchForMode(display_id, 16, width, height, match);

    // still no match? fallback to current resolution of the display which HAS to work [tm]
    if (!match)
    {
      int tmpWidth;
      int tmpHeight;
      double tmpRefresh;

      GetScreenResolution(&tmpWidth, &tmpHeight, &tmpRefresh, screenIdx);
      dispMode = GetMode(tmpWidth, tmpHeight, tmpRefresh, screenIdx);

      // no way to get a resolution set
      if (!dispMode)
        return false;
    }

    if (!match)
      return false;
  }

  // switch mode and return success
  CGDisplayCapture(display_id);
  CGDisplayConfigRef cfg;
  CGBeginDisplayConfiguration(&cfg);
  CGConfigureDisplayWithDisplayMode(cfg, display_id, dispMode, nullptr);
  CGError err = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
  CGDisplayRelease(display_id);

  m_refreshRate = CGDisplayModeGetRefreshRate(dispMode);

  Cocoa_CVDisplayLinkUpdate();

  return (err == kCGErrorSuccess);
}

void CWinSystemOSX::FillInVideoModes()
{
  // Add full screen settings for additional monitors
  int numDisplays = [[NSScreen screens] count];

  for (int disp = 0; disp < numDisplays; disp++)
  {
    Boolean stretched;
    Boolean interlaced;
    Boolean safeForHardware;
    Boolean televisionoutput;
    int w, h, bitsperpixel;
    double refreshrate;
    RESOLUTION_INFO res;

    CFArrayRef displayModes = CGDisplayCopyAllDisplayModes(GetDisplayID(disp), nullptr);
    NSString *dispName = screenNameForDisplay(GetDisplayID(disp));

    if (dispName != nil)
    {
      CLog::Log(LOGNOTICE, "Display %i has name %s", disp, [dispName UTF8String]);
    }

    if (NULL == displayModes)
      continue;

    for (int i=0; i < CFArrayGetCount(displayModes); ++i)
    {
      CGDisplayModeRef displayMode = (CGDisplayModeRef)CFArrayGetValueAtIndex(displayModes, i);

      uint32_t flags = CGDisplayModeGetIOFlags(displayMode);
      stretched = flags & kDisplayModeStretchedFlag ? true : false;
      interlaced = flags & kDisplayModeInterlacedFlag ? true : false;
      bitsperpixel = DisplayBitsPerPixelForMode(displayMode);
      safeForHardware = flags & kDisplayModeSafetyFlags ? true : false;
      televisionoutput = flags & kDisplayModeTelevisionFlag ? true : false;

      if ((bitsperpixel == 32)      &&
          (safeForHardware == YES)  &&
          (stretched == NO)         &&
          (interlaced == NO))
      {
        w = CGDisplayModeGetWidth(displayMode);
        h = CGDisplayModeGetHeight(displayMode);
        refreshrate = CGDisplayModeGetRefreshRate(displayMode);
        if ((int)refreshrate == 0)  // LCD display?
        {
          // NOTE: The refresh rate will be REPORTED AS 0 for many DVI and notebook displays.
          refreshrate = 60.0;
        }
        CLog::Log(LOGNOTICE, "Found possible resolution for display %d with %d x %d @ %f Hz\n", disp, w, h, refreshrate);

        UpdateDesktopResolution(res, disp, w, h, refreshrate);

        // overwrite the mode str because  UpdateDesktopResolution adds a
        // "Full Screen". Since the current resolution is there twice
        // this would lead to 2 identical resolution entrys in the guisettings.xml.
        // That would cause problems with saving screen overscan calibration
        // because the wrong entry is picked on load.
        // So we just use UpdateDesktopResolutions for the current DESKTOP_RESOLUTIONS
        // in UpdateResolutions. And on all other resolutions make a unique
        // mode str by doing it without appending "Full Screen".
        // this is what linux does - though it feels that there shouldn't be
        // the same resolution twice... - thats why i add a FIXME here.
        res.strMode = StringUtils::Format("%dx%d @ %.2f", w, h, refreshrate);

        if (dispName != nil)
        {
          res.strOutput = [dispName UTF8String];
        }

        g_graphicsContext.ResetOverscan(res);
        CDisplaySettings::GetInstance().AddResolutionInfo(res);
      }
    }
    CFRelease(displayModes);
  }
}
bool CWinSystemOSX::FlushBuffer(void)
{
  if (m_appWindow)
  {
    OSXGLView *contentView = [(NSWindow *)m_appWindow contentView];
    NSOpenGLContext *glcontex = [contentView getGLContext];
    [glcontex flushBuffer];
  }
  return true;
}

void CWinSystemOSX::NotifyAppFocusChange(bool bGaining)
{
  //printf("CWinSystemOSX::NotifyAppFocusChange\n");
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  if (m_bFullScreen && bGaining)
  {
    // find the window
    NSOpenGLContext* context = [NSOpenGLContext currentContext];
    if (context)
    {
      NSView* view;

      view = [context view];
      if (view)
      {
        NSWindow* window;
        window = [view window];
        if (window)
        {
          [window orderFront:nil];
        }
      }
    }
  }
  [pool release];
}

void CWinSystemOSX::ShowOSMouse(bool show)
{
  //printf("CWinSystemOSX::ShowOSMouse %d\n", show);
  if (show)
  {
    Cocoa_ShowMouse();
  }
  else
  {
    Cocoa_HideMouse();
  }
}

bool CWinSystemOSX::Minimize()
{
  //printf("CWinSystemOSX::Minimize\n");
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  [[NSApplication sharedApplication] miniaturizeAll:nil];

  [pool release];
  return true;
}

bool CWinSystemOSX::Restore()
{
  //printf("CWinSystemOSX::Restore\n");
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  [[NSApplication sharedApplication] unhide:nil];

  [pool release];
  return true;
}

bool CWinSystemOSX::Hide()
{
  //printf("CWinSystemOSX::Hide\n");
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  [[NSApplication sharedApplication] hide:nil];

  [pool release];
  return true;
}

OSXTextInputResponder *g_textInputResponder = nil;
bool CWinSystemOSX::IsTextInputEnabled()
{
  //printf("CWinSystemOSX::IsTextInputEnabled\n");
  return g_textInputResponder != nil && [[g_textInputResponder superview] isEqual: [[NSApp keyWindow] contentView]];
}

void CWinSystemOSX::StartTextInput()
{
  //printf("CWinSystemOSX::StartTextInput\n");
  NSView *parentView = [[NSApp keyWindow] contentView];

  /* We only keep one field editor per process, since only the front most
   * window can receive text input events, so it make no sense to keep more
   * than one copy. When we switched to another window and requesting for
   * text input, simply remove the field editor from its superview then add
   * it to the front most window's content view */
  if (!g_textInputResponder) {
    g_textInputResponder =
    [[OSXTextInputResponder alloc] initWithFrame: NSMakeRect(0.0, 0.0, 0.0, 0.0)];
  }

  if (![[g_textInputResponder superview] isEqual: parentView])
  {
    //    DLOG(@"add fieldEdit to window contentView");
    [g_textInputResponder removeFromSuperview];
    [parentView addSubview: g_textInputResponder];
    [[NSApp keyWindow] makeFirstResponder: g_textInputResponder];
  }
}
void CWinSystemOSX::StopTextInput()
{
  //printf("CWinSystemOSX::StopTextInput\n");
  if (g_textInputResponder) {
    [g_textInputResponder removeFromSuperview];
    [g_textInputResponder release];
    g_textInputResponder = nil;
  }
}

void CWinSystemOSX::Register(IDispResource *resource)
{
  //printf("CWinSystemOSX::Register\n");
  CSingleLock lock(m_resourceSection);
  m_resources.push_back(resource);
}

void CWinSystemOSX::Unregister(IDispResource* resource)
{
  //printf("CWinSystemOSX::Unregister\n");
  CSingleLock lock(m_resourceSection);
  std::vector<IDispResource*>::iterator i = find(m_resources.begin(), m_resources.end(), resource);
  if (i != m_resources.end())
    m_resources.erase(i);
}


void CWinSystemOSX::AnnounceOnLostDevice()
{
  CSingleLock lock(m_resourceSection);
  // tell any shared resources
  CLog::Log(LOGDEBUG, "CWinSystemOSX::AnnounceOnLostDevice");
  for (std::vector<IDispResource *>::iterator i = m_resources.begin(); i != m_resources.end(); i++)
    (*i)->OnLostDisplay();
}

void CWinSystemOSX::HandleOnResetDevice()
{
  int delay = CServiceBroker::GetSettings().GetInt("videoscreen.delayrefreshchange");
  if (delay > 0)
  {
    m_delayDispReset = true;
    m_dispResetTimer.Set(delay * 100);
  }
  else
  {
    AnnounceOnResetDevice();
  }
}

void CWinSystemOSX::AnnounceOnResetDevice()
{
  CSingleLock lock(m_resourceSection);
  // tell any shared resources
  CLog::Log(LOGDEBUG, "CWinSystemOSX::AnnounceOnResetDevice");
  for (std::vector<IDispResource *>::iterator i = m_resources.begin(); i != m_resources.end(); i++)
    (*i)->OnResetDisplay();
}

std::string CWinSystemOSX::GetClipboardText(void)
{
  std::string utf8_text;

  const char *szStr = Cocoa_Paste();
  if (szStr)
    utf8_text = szStr;

  return utf8_text;
}

float CWinSystemOSX::CocoaToNativeFlip(float y)
{
  // OpenGL specifies that the default origin is at bottom-left.
  // Cocoa specifies that the default origin is at bottom-left.
  // Direct3D specifies that the default origin is at top-left.
  // SDL specifies that the default origin is at top-left.
  // WTF ?

  // TODO hook height and width up to resize events of window and cache them as member
  if (m_appWindow)
  {
    NSWindow *win = (NSWindow *)m_appWindow;
    NSRect frame = [[win contentView] frame];
    y = frame.size.height - y;
  }
  return y;
}

std::unique_ptr<IOSScreenSaver> CWinSystemOSX::GetOSScreenSaverImpl()
{
  return std::unique_ptr<IOSScreenSaver> (new COSScreenSaverOSX);
}

void CWinSystemOSX::EnableTextInput(bool bEnable)
{
  //printf("CWinSystemOSX::EnableTextInput\n");
  if (bEnable)
    StartTextInput();
  else
    StopTextInput();
}

bool CWinSystemOSX::Show(bool raise)
{
  //printf("CWinSystemOSX::Show\n");
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  if (raise)
  {
    [[NSApplication sharedApplication] unhide:nil];
    [[NSApplication sharedApplication] activateIgnoringOtherApps: YES];
    [[NSApplication sharedApplication] arrangeInFront:nil];
  }
  else
  {
    [[NSApplication sharedApplication] unhideWithoutActivation];
  }

  [pool release];
  return true;
}

int CWinSystemOSX::GetNumScreens()
{
  int numDisplays = [[NSScreen screens] count];
  return(numDisplays);
}

int CWinSystemOSX::GetCurrentScreen()
{

  // if user hasn't moved us in windowed mode - return the
  // last display we were fullscreened at
  if (!m_movedToOtherScreen)
    return m_lastDisplayNr;

  if (m_appWindow)
  {
    m_movedToOtherScreen = false;
    return GetDisplayIndex(GetDisplayIDFromScreen( [(NSWindow *)m_appWindow screen]));
  }
  return 0;
}

CGLContextObj CWinSystemOSX::GetCGLContextObj()
{
  CGLContextObj cglcontex = NULL;
  if(m_appWindow)
  {
    OSXGLView *contentView = [(NSWindow*)m_appWindow contentView];
    cglcontex = [[contentView getGLContext] CGLContextObj];
  }

  return cglcontex;
}

void CWinSystemOSX::SetMovedToOtherScreen(bool moved)
{
  m_movedToOtherScreen = moved;
  if (moved)
  {
    HandlePossibleRefreshrateChange();
  }
}

void CWinSystemOSX::HandlePossibleRefreshrateChange()
{
  static double oldRefreshRate = m_refreshRate;
  Cocoa_CVDisplayLinkUpdate();
  int dummy = 0;

  GetScreenResolution(&dummy, &dummy, &m_refreshRate, GetCurrentScreen());

  if (oldRefreshRate != m_refreshRate)
  {
    oldRefreshRate = m_refreshRate;
    // send a message so that videoresolution (and refreshrate) is changed
    NSWindow *win = (NSWindow *)m_appWindow;
    NSRect frame = [[win contentView] frame];
    KODI::MESSAGING::CApplicationMessenger::GetInstance().PostMsg(TMSG_VIDEORESIZE, frame.size.width, frame.size.height);
  }
}


// TODO from here on - all methods might be relevant to misbehavior!
bool CWinSystemOSX::CreateNewWindow(const std::string& name, bool fullScreen, RESOLUTION_INFO& res)
{
  //printf("CWinSystemOSX::CreateNewWindow\n");
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  
  m_nWidth      = res.iWidth;
  m_nHeight     = res.iHeight;
  m_bFullScreen = fullScreen;
  m_name        = name;

  NSDisableScreenUpdates();

  // for native fullscreen we always want to set the same windowed flags
  NSUInteger windowStyleMask;

  windowStyleMask = NSTitledWindowMask|NSResizableWindowMask|NSClosableWindowMask|NSWindowStyleMaskMiniaturizable;

  if (m_appWindow == NULL)
  {
    NSWindow *appWindow = [[OSXGLWindow alloc] initWithContentRect:NSMakeRect(0, 0, m_nWidth, m_nHeight) styleMask:windowStyleMask];
    NSString *title = [NSString stringWithUTF8String:m_name.c_str()];
    [appWindow setBackgroundColor:[NSColor blackColor]];
    [appWindow setTitle:title];
    [appWindow setOneShot:NO];

    NSWindowCollectionBehavior behavior = [appWindow collectionBehavior];
    behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    [appWindow setCollectionBehavior:behavior];

    // create new content view
    NSRect rect = [appWindow contentRectForFrameRect:[appWindow frame]];

    // create new view if we don't have one
    if(!m_glView)
      m_glView = [[OSXGLView alloc] initWithFrame:rect];
    OSXGLView *contentView = (OSXGLView*)m_glView;

    // associate with current window
    [appWindow setContentView: contentView];
    [[contentView getGLContext] makeCurrentContext];
    [[contentView getGLContext] update];

    m_appWindow = appWindow;
    m_bWindowCreated = true;
  }

  [(NSWindow*)m_appWindow makeKeyAndOrderFront:nil];

  NSEnableScreenUpdates();

  // check if we have to hide the mouse after creating the window
  // in case we start windowed with the mouse over the window
  // the tracking area mouseenter, mouseexit are not called
  // so we have to decide here to initial hide the os cursor
  NSPoint mouse = [NSEvent mouseLocation];
  if ([NSWindow windowNumberAtPoint:mouse belowWindowWithWindowNumber:0] == ((NSWindow *)m_appWindow).windowNumber)
  {
    // warp XBMC cursor to our position
    NSPoint locationInWindowCoords = [(NSWindow *)m_appWindow mouseLocationOutsideOfEventStream];
    XBMC_Event newEvent;
    memset(&newEvent, 0, sizeof(newEvent));
    newEvent.type = XBMC_MOUSEMOTION;
    newEvent.motion.x =  locationInWindowCoords.x;
    newEvent.motion.y =  locationInWindowCoords.y;
    g_application.OnEvent(newEvent);
  }
  [pool release];

  SetFullScreen(m_bFullScreen, res, false);

  // register platform dependent objects
  CDVDFactoryCodec::ClearHWAccels();
  VTB::CDecoder::Register();
  VIDEOPLAYER::CRendererFactory::ClearRenderer();
  CLinuxRendererGL::Register();
  CRendererVTB::Register();

  return true;
}

// this is either called from SetFullScreen (so internally) or
// from windowDidEndLiveResize as a result of
// TMSG_VIDEORESIZE (externally) - it makes it hard to get
// right due to miss understanding the whole nswindow/nsview
// coordinate system
bool CWinSystemOSX::ResizeWindow(int newWidth, int newHeight, int newLeft, int newTop)
{
  //printf("CWinSystemOSX::ResizeWindow\n");
  if (!m_appWindow)
    return false;

  if (newLeft < 0)
  {
    newLeft = m_lastX;
  }

  if (newTop < 0)
  {
    newTop = m_lastY;
  }

  if (newWidth < 0)
  {
    newWidth = 800;
  }

  if (newHeight < 0)
  {
    newHeight = 400;
  }

  NSRect myNewFrame = NSMakeRect(newLeft, newTop, newWidth, newHeight);
  NSWindow *window = (NSWindow*)m_appWindow;
  OSXGLView *view = [window contentView];
  NSOpenGLContext *context = [view getGLContext];

  [window setContentSize:myNewFrame.size];
  [window setFrame:myNewFrame display:TRUE];
  [view setFrameOrigin:NSMakePoint(0, 0)];
  [view setFrameSize:myNewFrame.size];
  [context update];

  m_nWidth = newWidth;
  m_nHeight = newHeight;

  return true;

}

// this not only toggles full screen - it also
// needs to move from screen to screen if needed
// either when moving the windowed mode to a different
// screen and toggle fullscreen or by moveing from full
// screen #1 to #2 for example.
// the idea is to Make use of the native full screen
// handling as much as possible here and only do as
// much resizing/moving programmatically as needed.
bool CWinSystemOSX::SetFullScreen(bool fullScreen, RESOLUTION_INFO& res, bool blankOtherDisplays)
{
  CSingleLock lock (m_critSection);

  if (m_appWindow == NULL)
    CreateNewWindow(m_name, m_bFullScreen, res);

  OSXGLWindow *window = (OSXGLWindow *)m_appWindow;

  m_nWidth      = res.iWidth;
  m_nHeight     = res.iHeight;
  m_bFullScreen = fullScreen;
  m_lastDisplayNr = res.iScreen;

  [window setAllowsConcurrentViewDrawing:NO];

  if (m_bFullScreen)
  {
    // switch videomode
    SwitchToVideoMode(res.iWidth, res.iHeight, res.fRefreshRate, res.iScreen);
    NSScreen* pScreen = [[NSScreen screens] objectAtIndex:res.iScreen];
    NSRect    screenRect = [pScreen frame];
    ResizeWindow(m_nWidth, m_nHeight, screenRect.origin.x, screenRect.origin.y);
  }
  else
  {
    // Windowed Mode
    ResizeWindow(m_nWidth, m_nHeight, m_lastX, m_lastY);
  }

  m_fullscreenWillToggle = m_bFullScreen != [window isFullScreen];

  // toggle cocoa fullscreen mode
  // this should handle everything related to
  // window decorations and stuff like that.
  if (m_fullscreenWillToggle)
  {
    [window performSelectorOnMainThread:@selector(toggleFullScreen:) withObject:nil waitUntilDone:YES];
  }


  [window setAllowsConcurrentViewDrawing:YES];

  return true;
}

void CWinSystemOSX::OnMove(int x, int y)
{
  //printf("CWinSystemOSX::OnMove\n");
  m_lastX      = x;
  m_lastY      = y;
}

#endif
