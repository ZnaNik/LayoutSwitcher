// mtswipe.c — trackpad gestures for a page launcher (LaunchNext), ACTIVE ONLY
// while that launcher is frontmost (gate set from Swift via mtswipe_set_active):
//   • 3 fingers sideways      -> precise scroll gesture (page flip).
//   • 2 fingers fast flick up -> Escape (hide). Velocity is computed as Δpos/Δt in
//     NORMALIZED-pad-units per second (a known scale: ~1.0 = cross the whole pad in 1s),
//     so the threshold is meaningful without per-machine calibration. Fires instantly
//     on a sharp flick without nudging the page; slow scrolls are ignored.
// Logs to ~/Library/Logs/lsswipe.log (incl. peak 2-finger up-velocity for tuning).
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <math.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
    int   frame; double timestamp;
    int   identifier, state, fingerId, handId;
    MTVector normalized; float size; int zero1;
    float angle, majorAxis, minorAxis;
    MTVector absoluteVector; int zero2[2]; float zDensity;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, MTTouch *, int, double, int);
extern CFMutableArrayRef MTDeviceCreateList(void);
extern void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
extern void MTDeviceStart(MTDeviceRef, int);

static double gGain     = -1500.0;  // 3-finger horizontal sensitivity/direction
static double gFlickVel = 4.0;      // 2-finger up-flick speed to hide (pad-units/sec); signed; 0 = off
static double gDeadzone = 0.02;     // horizontal travel before paging starts
static int    gAppActive = 0;

static int   gMode = 0;             // 0 none, 3 paging, 2 hide-watch
static int   gPbegun = 0; static float gPstartX = 0, gPlastX = 0;
static int   gHfired = 0; static float gHprevX = 0, gHprevY = 0; static double gHprevTs = 0, gHpeakV = 0;
static int   gSessionMax = 0;

// Вне лаунчера: 3 пальца вбок -> переключение Spaces (Ctrl+стрелка), один раз за жест.
static int    gSpMode = 0, gSpFired = 0; static float gSpStartX = 0;
static double gSpThreshold = 0.12;  // доля ширины пада до срабатывания
static int    gSpInvert = 0;        // 1 = инвертировать направление

static FILE *gLog = NULL;
static double now_s(void) { return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9; }
static void lg(const char *fmt, ...) {
    if (!gLog) return;
    va_list ap; va_start(ap, fmt); vfprintf(gLog, fmt, ap); va_end(ap);
    fprintf(gLog, "\n"); fflush(gLog);
}
void mtswipe_log(const char *m) { lg("[%.3f] %s", now_s(), m); }

static void postPhase(double hdelta, int64_t phase) {
    CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, 0, 0);
    if (!e) return;
    CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase, phase);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventPointDeltaAxis2, (int64_t)llround(hdelta));
    CGEventSetDoubleValueField(e,  kCGScrollWheelEventFixedPtDeltaAxis2, hdelta);
    CGEventPost(kCGHIDEventTap, e); CFRelease(e);
}
static void postKey(CGKeyCode k) {
    CGEventRef d = CGEventCreateKeyboardEvent(NULL, k, true);
    CGEventRef u = CGEventCreateKeyboardEvent(NULL, k, false);
    if (d) { CGEventPost(kCGHIDEventTap, d); CFRelease(d); }
    if (u) { CGEventPost(kCGHIDEventTap, u); CFRelease(u); }
}
// Ctrl+клавиша как РЕАЛЬНАЯ последовательность: физически нажать Control,
// затем клавишу, отпустить, отпустить Control. Для системного переключения
// Spaces одного флага мало — нужно настоящее удержание модификатора.
#define VK_LCONTROL 0x3B
static void postKeyMod(CGKeyCode k, CGEventFlags flags) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef cD = CGEventCreateKeyboardEvent(src, VK_LCONTROL, true);
    CGEventRef kD = CGEventCreateKeyboardEvent(src, k, true);
    CGEventRef kU = CGEventCreateKeyboardEvent(src, k, false);
    CGEventRef cU = CGEventCreateKeyboardEvent(src, VK_LCONTROL, false);
    if (cD) { CGEventSetFlags(cD, flags); CGEventPost(kCGHIDEventTap, cD); CFRelease(cD); }
    if (kD) { CGEventSetFlags(kD, flags); CGEventPost(kCGHIDEventTap, kD); CFRelease(kD); }
    if (kU) { CGEventSetFlags(kU, flags); CGEventPost(kCGHIDEventTap, kU); CFRelease(kU); }
    if (cU) { CGEventSetFlags(cU, 0);     CGEventPost(kCGHIDEventTap, cU); CFRelease(cU); }
    if (src) CFRelease(src);
}
static void endPaging(void) { if (gPbegun) { postPhase(0, 4); gPbegun = 0; } }
static void endHideWatch(void) {
    if (gMode == 2 && fabs(gHpeakV) > 1.0) lg("[%.3f] 2f peakUpVel=%.2f u/s (tune swipeFlickVel near a real flick's peak)", now_s(), gHpeakV);
    gHpeakV = 0;
}

static int mt_callback(MTDeviceRef dev, MTTouch *t, int n, double ts, int frame) {
    (void)dev; (void)frame;

    // ВНЕ лаунчера: не вмешиваемся — система сама листает Spaces нативным
    // 3-пальцевым свайпом (синтетический Ctrl+стрелка macOS игнорирует by design).
    if (!gAppActive) { endPaging(); endHideWatch(); gMode = 0; gSessionMax = 0; return 0; }

    int active = 0; float sumX = 0, sumY = 0;
    for (int i = 0; i < n; i++)
        if (t[i].state == 4 || t[i].state == 3) { active++; sumX += t[i].normalized.pos.x; sumY += t[i].normalized.pos.y; }
    if (active > gSessionMax) gSessionMax = active;

    if (active == 3) {                                   // ---- paging ----
        if (gMode == 2) endHideWatch();
        float avgX = sumX / 3.0f;
        if (gMode != 3) { gMode = 3; gPstartX = avgX; gPlastX = avgX; gPbegun = 0; }
        if (!gPbegun) {
            if (fabsf(avgX - gPstartX) > (float)gDeadzone) {
                postPhase(0, 1); gPbegun = 1; lg("[%.3f] page BEGAN", now_s());
                double dx = (double)(avgX - gPlastX) * gGain; gPlastX = avgX; if (dx != 0.0) postPhase(dx, 2);
            }
        } else {
            double dx = (double)(avgX - gPlastX) * gGain; gPlastX = avgX; if (dx != 0.0) postPhase(dx, 2);
        }
    } else if (active == 2 && gFlickVel != 0.0 && gSessionMax <= 2) {   // ---- hide: fast up flick ----
        endPaging();
        float avgX = sumX / 2.0f, avgY = sumY / 2.0f;
        if (gMode != 2) { gMode = 2; gHfired = 0; gHpeakV = 0; gHprevX = avgX; gHprevY = avgY; gHprevTs = ts; }
        else {
            double dt = ts - gHprevTs;
            if (dt > 0.0005) {                            // ignore zero/garbage dt
                double vy = (double)(avgY - gHprevY) / dt; // +up (normalized y increases upward)
                double vx = (double)(avgX - gHprevX) / dt;
                if (fabs(vy) > fabs(gHpeakV)) gHpeakV = vy;
                if (!gHfired) {
                    int flick = (gFlickVel > 0.0) ? (vy >= gFlickVel) : (vy <= gFlickVel);
                    if (flick && fabs(vy) > fabs(vx)) { postKey(53); gHfired = 1; lg("[%.3f] HIDE flick vy=%.2f u/s", now_s(), vy); }
                }
                gHprevX = avgX; gHprevY = avgY; gHprevTs = ts;
            }
        }
    } else {                                             // ---- released / 3->2 leftover / other ----
        endPaging(); endHideWatch(); gMode = 0;
        if (active == 0) gSessionMax = 0;
    }
    return 0;
}

void mtswipe_set_active(int on) {
    on = on ? 1 : 0;
    if (on != gAppActive) lg("[%.3f] set_active=%d", now_s(), on);
    if (!on) { endPaging(); endHideWatch(); gMode = 0; gSessionMax = 0; }
    gAppActive = on;
}

void mtswipe_start(double gain, double flickVel) {
    gGain = gain; gFlickVel = flickVel;
    const char *home = getenv("HOME");
    if (home) { char p[1024]; snprintf(p, sizeof(p), "%s/Library/Logs/lsswipe.log", home); gLog = fopen(p, "a"); }
    const char *dz = getenv("LS_DEADZONE"); if (dz) gDeadzone = atof(dz);
    const char *st = getenv("LS_SPACE_THRESHOLD"); if (st) gSpThreshold = atof(st);
    const char *si = getenv("LS_SPACE_INVERT"); if (si) gSpInvert = atoi(si);
    lg("[%.3f] === mtswipe_start gain=%.0f flickVel=%.2f u/s deadzone=%.3f ===", now_s(), gGain, gFlickVel, gDeadzone);
    CFMutableArrayRef devs = MTDeviceCreateList();
    if (!devs) { lg("no MT devices"); return; }
    CFIndex c = CFArrayGetCount(devs);
    for (CFIndex i = 0; i < c; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(devs, i);
        MTRegisterContactFrameCallback(d, mt_callback);
        MTDeviceStart(d, 0);
    }
    lg("[%.3f] listening on %ld device(s)", now_s(), (long)c);
}
