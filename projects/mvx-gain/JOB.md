# Setting a USB mic preamp without installing the maker's audio driver

| Tool | Status | Stack |
|---|---|---|
| MVX Gain | working on the bench | Swift, SwiftUI, Core Audio (single file, shell build script) |

## The job
A panelist or a room laptop joins a Zoom webinar through a Shure MVX2U, a small XLR to USB interface with a digital preamp. The gain has no knob. It is set from the maker's desktop app. So on every show Mac somebody installs that app, opens it, sets the gain, and leaves it running. Mid show the far end says they cannot hear the room, and the tech finds that Zoom has lost the microphone from its device list or switched to a virtual device the app created.

## Why it is hard
- The maker's app installs a virtual audio driver and its own virtual devices. Conferencing apps then see two or three inputs with similar names, and "Same as System" may point at the wrong one.
- When the chosen interface vanishes, macOS quietly moves the default input somewhere else. I have seen an app land on the virtual device and read dead silence.
- Zoom sometimes drops a USB mic from its list and will not find it again until the audio system restarts. Restarting it interrupts every app's audio for a few seconds, including a live call, and needs an administrator password.
- The preamp's phantom power, auto level and denoiser are not Core Audio properties. They travel over a private HID channel.
- A menu bar meter opens the microphone, which lights the orange privacy dot. Leave it running and the operator thinks something is recording.
- Gain is stored per device. Unplug and replug, or swap to a second unit, and it comes back at whatever it was last.

## What the machine does now
A menu bar app in one Swift file. It lists every input device whose Core Audio input volume is settable in dB, plus knob only interfaces so their other buttons still work. For the selected device it shows the gain range, a slider, three preset buttons (24, 36 and 48 dB by default), mute, and a level meter that runs only while the panel is open. It remembers gain per device ID and re-applies it when the device reconnects. One button makes the device the Mac default input, which fixes a conferencing app set to follow the system. Another restarts the macOS audio daemon after a confirmation that says plainly what will be interrupted, then re-applies the remembered gain. It uses no driver, no audio plug-in and no helper process. The build script signs with hardened runtime and the microphone entitlement.

## What still needs a person
Choosing the gain by listening and watching the meter with the actual talker. Setting phantom power, auto level and the denoiser once from the maker's phone app, since this tool cannot reach them. Deciding whether an audio restart is worth the interruption during a live call. I have built it and run it at a desk. I have no record yet of it carrying a show.

## Rebuilding it
Everything is `AudioObjectGetPropertyData` and `AudioObjectSetPropertyData`. Enumerate devices from the system object, keep those with input channels, and test whether the input scope volume in decibels is present and settable. Read its range for the slider. Write the scalar dB value to set gain and the mute property to mute. Listen for changes to the device list and the default input so the UI follows hot plugs.

Identify devices by UID and never by name or object ID, because the ID changes on every plug. Store gain per UID in user defaults and restore on connect, with a switch to turn that off. Run the meter from a short lived audio engine tied to panel visibility. Do the audio restart through a privileged shell command so the OS shows its own password prompt, then wait about 3 seconds and rescan, because the device listener does not always fire after the daemon returns. Install to the Applications folder, never a cloud synced folder, which adds attributes that fail strict signature checks.
