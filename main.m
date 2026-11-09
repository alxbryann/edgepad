// EdgePad: trackpad edges -> right: volume, left: brightness, bottom: scrub (Spotify/Music if playing,
// else arrow keys). Corner taps: top-left/top-right run line 1/2 of ~/.config/edgepad/corners,
// bottom-left/bottom-right = previous/next track. Run with -v to log touches.
#import <Cocoa/Cocoa.h>
#import <dlfcn.h>

// Layout of MultitouchSupport's private touch record.
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
  int frame; double timestamp; int identifier, state, fingerId, handId;
  MTVector normalized; float size; int zero1;
  float angle, majorAxis, minorAxis; MTVector mm; int zero2[2]; float unk2;
} MTTouch;
_Static_assert(sizeof(MTTouch) == 96, "MTTouch layout");
typedef int (*MTCallback)(void *, MTTouch *, int, double, int);

enum { NONE, IGNORE, RIGHT, LEFT, BOTTOM, TOPLEFT, TOPRIGHT, BOTTOMLEFT, BOTTOMRIGHT };
enum { SOUND_UP = 0, SOUND_DOWN = 1, BRIGHT_UP = 2, BRIGHT_DOWN = 3, NEXT = 17, PREVIOUS = 18 };
static const float EDGE = 0.06, CORNER = 0.12, ENGAGE = 0.015, STEP = 0.06, SCRUB_STEP = 0.05,
                   TAP_SLOP = 0.03, SCRUB_SECONDS = 5;
static const double TAP_TIME = 0.3, CLICK_GRACE = 0.35;

static int mode = NONE, engaged = 0, verbose = 0;
static float startX, startY, lastX, lastY, accum;
static double startT;
static volatile int blocking = 0, inCorner = 0, physicalClick = 0;
static volatile double unblockAt = 0;
static CGPoint frozenAt;
static CFMachPortRef eventTap;
static NSString *scrubApp; // main thread only

static void mediaKey(int key) {
  for (int down = 1; down >= 0; down--) {
    NSEvent *e = [NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint
                               modifierFlags:(down ? 0xa00 : 0xb00) timestamp:0 windowNumber:0
                                     context:nil subtype:8
                                       data1:(key << 16) | ((down ? 0xa : 0xb) << 8) data2:-1];
    CGEventPost(kCGHIDEventTap, e.CGEvent);
  }
}

static void arrowKey(int right) {
  for (int down = 1; down >= 0; down--) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, right ? 124 : 123, down);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
  }
}

static NSAppleEventDescriptor *runScript(NSString *src) {
  return [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:nil];
}

// Only scripts players that are already running, so AppleScript never launches or hunts for an app.
static NSString *playingMusicApp(void) {
  NSDictionary *players = @{@"com.spotify.client" : @"Spotify", @"com.apple.Music" : @"Music"};
  for (NSString *bundle in players) {
    if (![NSRunningApplication runningApplicationsWithBundleIdentifier:bundle].count) continue;
    NSString *src = [NSString stringWithFormat:@"tell application \"%@\" to player state is playing", players[bundle]];
    if (runScript(src).booleanValue) return players[bundle];
  }
  return nil;
}

static void scrub(int forward) {
  if (!scrubApp) { arrowKey(forward); return; }
  runScript([NSString stringWithFormat:@"tell application \"%@\" to set player position to (player position %@ %g)",
                                       scrubApp, forward ? @"+" : @"-", SCRUB_SECONDS]);
}

static void runCorner(int line) {
  NSString *path = [@"~/.config/edgepad/corners" stringByExpandingTildeInPath];
  NSArray *lines = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
                    componentsSeparatedByString:@"\n"];
  NSString *cmd = lines.count > line ? lines[line] : @"";
  if (cmd.length) [NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:@[ @"-c", cmd ]];
}

static void cornerAction(int corner) {
  if (corner == TOPLEFT) runCorner(0);
  if (corner == TOPRIGHT) runCorner(1);
  if (corner == BOTTOMLEFT) mediaKey(PREVIOUS);
  if (corner == BOTTOMRIGHT) mediaKey(NEXT);
}

static int edgeMode(float x, float y) {
  return x > 1 - EDGE ? RIGHT : x < EDGE ? LEFT : y < EDGE ? BOTTOM : IGNORE;
}

static void block(void) {
  CGEventRef e = CGEventCreate(NULL);
  frozenAt = CGEventGetLocation(e);
  CFRelease(e);
  blocking = 1;
}

// grace keeps swallowing the tap-to-click the driver sends right after the finger lifts.
static void end(int grace) {
  if (blocking) unblockAt = CFAbsoluteTimeGetCurrent() + (grace ? CLICK_GRACE : 0);
  blocking = inCorner = 0;
  mode = NONE;
  engaged = 0;
}

static void repeat(float delta, float size, void (^act)(int up)) {
  accum += delta;
  for (; accum >= size; accum -= size) dispatch_async(dispatch_get_main_queue(), ^{ act(1); });
  for (; accum <= -size; accum += size) dispatch_async(dispatch_get_main_queue(), ^{ act(0); });
}

static int touches(void *dev, MTTouch *t, int n, double ts, int frame) {
  int down = 0;
  MTTouch *f = NULL;
  for (int i = 0; i < n; i++)
    if (t[i].state == 4) { down++; f = &t[i]; }

  if (down == 0) {
    if (inCorner && !physicalClick && ts - startT < TAP_TIME) {
      int corner = mode;
      dispatch_async(dispatch_get_main_queue(), ^{ cornerAction(corner); });
    }
    end(mode != IGNORE && !physicalClick);
    return 0;
  }
  // More than one finger is a normal macOS gesture: stay out of it until all fingers lift.
  if (down > 1 || mode == IGNORE) {
    if (mode != IGNORE) { end(0); mode = IGNORE; }
    return 0;
  }

  float x = f->normalized.pos.x, y = f->normalized.pos.y;
  if (verbose) fprintf(stderr, "x=%.3f y=%.3f mode=%d\n", x, y, mode);
  if (mode == NONE) {
    startX = lastX = x; startY = lastY = y; startT = ts; accum = 0; physicalClick = 0;
    int top = y > 1 - CORNER, bottom = y < CORNER, left = x < CORNER, right = x > 1 - CORNER;
    mode = top && left ? TOPLEFT : top && right ? TOPRIGHT : bottom && left ? BOTTOMLEFT
         : bottom && right ? BOTTOMRIGHT : edgeMode(x, y);
    if (mode >= TOPLEFT) { block(); inCorner = 1; }
    return 0;
  }

  float dx = x - lastX, dy = y - lastY;
  lastX = x; lastY = y;
  if (inCorner) {
    // A corner touch that slides is a normal edge gesture (or pointer move) that started in the corner.
    if (hypotf(x - startX, y - startY) > TAP_SLOP) { end(0); mode = edgeMode(startX, startY); }
    return 0;
  }
  if (!engaged) {
    // Only take over once the finger clearly slides along the edge, so plain clicks there still work.
    float along = fabsf(mode == BOTTOM ? x - startX : y - startY);
    float across = fabsf(mode == BOTTOM ? y - startY : x - startX);
    if (across > ENGAGE && across >= along) { mode = IGNORE; return 0; }
    if (along <= ENGAGE) return 0;
    engaged = 1;
    block();
    if (mode == BOTTOM) dispatch_async(dispatch_get_main_queue(), ^{ scrubApp = playingMusicApp(); });
  }
  if (mode == RIGHT) repeat(dy, STEP, ^(int up) { mediaKey(up ? SOUND_UP : SOUND_DOWN); });
  if (mode == LEFT) repeat(dy, STEP, ^(int up) { mediaKey(up ? BRIGHT_UP : BRIGHT_DOWN); });
  if (mode == BOTTOM) repeat(dx, SCRUB_STEP, ^(int right) { scrub(right); });
  return 0;
}

// Freezes the pointer and swallows clicks while an edge gesture owns the finger.
static CGEventRef onEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *ref) {
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    CGEventTapEnable(eventTap, true);
    return e;
  }
  // A click while the finger is still down in a corner is a physical press, not a tap: let it through.
  if (inCorner && type != kCGEventMouseMoved && type != kCGEventLeftMouseDragged) {
    physicalClick = 1;
    blocking = 0;
    return e;
  }
  if (!blocking && CFAbsoluteTimeGetCurrent() > unblockAt) return e;
  if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged) CGWarpMouseCursorPosition(frozenAt);
  return NULL;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    verbose = argc > 1 && !strcmp(argv[1], "-v");
    NSDictionary *prompt = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)prompt)) {
      // The grant is not seen by a running process, so exit and let launchd (KeepAlive) retry.
      fprintf(stderr, "edgepad: waiting for Accessibility permission\n");
      sleep(10);
      return 1;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp);
    eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask,
                                onEvent, NULL);
    if (!eventTap) { fprintf(stderr, "edgepad: cannot create event tap\n"); return 1; }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(NULL, eventTap, 0), kCFRunLoopCommonModes);

    void *mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    CFArrayRef (*createList)(void) = mt ? dlsym(mt, "MTDeviceCreateList") : NULL;
    void (*registerCallback)(void *, MTCallback) = mt ? dlsym(mt, "MTRegisterContactFrameCallback") : NULL;
    int (*start)(void *, int) = mt ? dlsym(mt, "MTDeviceStart") : NULL;
    if (!createList || !registerCallback || !start) { fprintf(stderr, "edgepad: MultitouchSupport unavailable\n"); return 1; }
    // shortcut: all trackpads share one gesture state, and new trackpads are only picked up on restart.
    CFArrayRef devices = createList();
    for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
      void *d = (void *)CFArrayGetValueAtIndex(devices, i);
      registerCallback(d, touches);
      start(d, 0);
    }
    fprintf(stderr, "edgepad: listening on %ld trackpad(s)\n", (long)CFArrayGetCount(devices));

    // Multitouch callbacks stop after sleep; exit and let launchd (KeepAlive) start a fresh process.
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidWakeNotification object:nil
                                                                 queue:nil usingBlock:^(NSNotification *n) { exit(0); }];
    CFRunLoopRun();
  }
  return 0;
}
