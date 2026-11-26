# Keeping a walking speaker in frame without a camera operator

| Tool | Status | Stack |
|---|---|---|
| ARC Follow (module inside ARC Camera OP) | partial | Swift (Apple Vision), Kotlin Multiplatform, ffmpeg |

## The job
A speaker who paces the stage needs someone riding the joystick for the whole talk. Many cameras have no tracker, and the built in ones pick their own subject.

I wanted a follower in my camera console that watches any camera's picture, follows the person I tap, and drives any head the console speaks to.

## Why it is hard
- Lag is the whole problem. The picture from a PTZ camera over the network is 100 to 600 ms old. With 300 ms of lag and a head that moves 60 degrees a second, my first loop overshot by 18 degrees. The lag has to be predicted away, not damped.
- The camera's own motion contaminates the measurement. When the head pans, the subject moves in frame while standing still. The loop has to remember what it commanded and put each detection back into a fixed frame before it estimates the subject's velocity.
- Stopping has to be immediate. A slew limit that suits speeding up makes the head overrun the dead band when it slows.
- Losing the subject must fail safe. A head driving on stale boxes swings off the stage.
- What is sold is closed or tied to one maker's cameras. The best open project is AGPL, so I copied its design ideas and none of its code.

## What the machine does now
Two parts are built and tested. Neither has moved a camera.

The detector is a small Swift program. It reads JPEG frames on standard input and writes one JSON line per frame, with person boxes as fractions of the frame and a confidence. It uses the Vision framework and ships no model file. It boxed a toy figure on a shelf at 0.56 confidence. On a 1280 wide stream it kept up with a camera's full 60 frames a second at about 7.6 ms per frame.

The controller is pure Kotlin with no clock and no camera of its own. Each tick takes the subject box, the frame time and a lag estimate. It returns pan and tilt velocity from minus 1 to 1, a zoom command and a state of idle, tracking, coasting or searching. It rebuilds the subject's path in a fixed frame, carries it forward over the lag and steers on that. On a synthetic stage a 12 degree step settles inside the band in one second with no reversal. On loss it coasts 400 ms and stops.

## What still needs a person
Everything about a real room. Every gain is a placeholder until a bench camera measures it. Still to build are the bench runner and scoring, the lag measurement, a dry run that logs commands without sending them, the console key, tap to pick, and the stage zone editor. A joystick touch must pause the follower at once.

Nobody is followed until the operator taps a person. Live loop tests are my own key presses. The score is time outside the target zone and time to reacquire, against the camera's own tracker on the same walk.

## Rebuilding it
Five parts. Eyes, subject choice, loop, head output, console. Keep the detector behind a pipe of JSON lines so the model swaps without touching the console. Keep the loop free of I/O so it can be unit tested on steps, ramps, loss and reacquire at several lags.

Each tick runs in order. Error from the target point, dead band with hysteresis, smoothing, proportional plus derivative with velocity feed forward, a catch up boost that grows with lag, clamp, response curve, slew limit on acceleration only. Send velocity through the same gate as the joystick, at each head's own command spacing (16 to 40 ms) and speed table. Resend stop until it is acknowledged.

Traps. A one euro filter must take its rate from the raw previous sample, or it reads four times too fast. On macOS a command line ffmpeg can be refused the local network, so bench scripts relay the stream through loopback.
