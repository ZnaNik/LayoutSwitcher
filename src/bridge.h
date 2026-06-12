#ifndef LAYOUTSWITCHER_BRIDGE_H
#define LAYOUTSWITCHER_BRIDGE_H

// Trackpad gestures for a page launcher (implemented in mtswipe.c):
//   gain     — 3-finger horizontal sensitivity/direction (page flip)
//   flickVel — signed 2-finger up-flick velocity to hide (Esc); 0 disables
void mtswipe_start(double gain, double flickVel);

// Enable gestures only while the launcher is frontmost (1) or not (0).
void mtswipe_set_active(int on);

// Append a diagnostic line to the swipe log.
void mtswipe_log(const char *msg);

#endif
