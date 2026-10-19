# Switching between desktop and terminal

In the desktop, open **Settings → Desktop → Switch to Terminal Mode**. The full-screen terminal has a **Desktop** button at the top to return to its desktop window.

Both interfaces show the same live terminal session: the app moves its existing view controller and WebView between the desktop window and the full-screen view. Switching does not create a new shell, reboot Linux, or require enabling JIT again. Other desktop windows and Linux processes remain open.

When Settings has focus, the switch uses the most recently focused terminal window. If no terminal window exists, it creates one. Starting in classic terminal mode and then opening the desktop adopts that existing terminal into a desktop window. The last selected interface is also saved for the next app launch; restarting the app still ends its running Linux processes as usual.

The desktop stays in memory during an in-app switch. Memory measurements from launching directly into classic mode therefore do not describe a desktop that is temporarily hidden.

## Device verification

- Record the native app PID, terminal session UUID, shell PID, and JIT status. Switch in both directions repeatedly and confirm those identities remain unchanged.
- Keep several lines of output and an unfinished input line visible. Check that they survive switching, opening and dismissing the keyboard, and rotating between portrait and landscape.
- Check that returning focuses the original terminal window, and that a hidden desktop does not consume classic terminal input or display its lock screen.
- Check classic-to-desktop adoption from a cold classic launch without starting a second shell.
- Exit the full-screen shell and confirm that the app returns to the desktop and closes only that terminal window.
