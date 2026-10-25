# Vocab Saver

A Windows app for saving English vocabulary while browsing the web, looking up meanings, and reviewing words with multiple-choice quizzes.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell (included with Windows).
- An internet connection to look up translations, phonetics, and definitions.

The app uses Windows Forms and does not run directly on Linux or macOS.

## Run the app

1. Download or extract the project on your Windows computer.
2. Open the project folder.
3. Double-click `VocabSaver.bat` to run the app in the background. A startup confirmation will appear. Then find the **(i)** icon in the system tray; it may be under the **^** menu next to the clock.

If the app does not start or you need to see error details, double-click `VocabSaver-Debug.bat`. The PowerShell window will display error information. You can also run it from PowerShell in the project folder:

```powershell
.\VocabSaver-Debug.bat
```

## How to use

1. While reading a web page, select an English word or phrase (up to 4 words) and press **Ctrl+C**.
2. The app checks the clipboard for matching text, saves the word, and displays a notification. If the word is already saved, the app will notify you instead of adding a duplicate.
3. Right-click the **(i)** system tray icon to access:
   - **Quiz now**: open a quiz when enough translated words are available.
   - **Pause review / Resume review**.
   - **Review interval**: choose an interval from 1 to 240 minutes (5 minutes by default).
   - **Word list**: view words, phonetics, meanings, definitions, and correct/incorrect counts.
   - **Exit**: close the app.
4. In the word list, double-click a word to edit it, click the speaker icon to hear it, or click the trash icon to delete it.

Quizzes appear automatically at the selected interval. At least 4 words with meanings are required for a quiz. The app prioritizes words you often get wrong and automatically pauses reviews when the computer is locked, during presentations/full-screen activity, or when a Teams call is detected.

## Data and privacy

- Saved words and settings are stored locally at `%APPDATA%\VocabSaver\words.json` and `%APPDATA%\VocabSaver\settings.json`.
- While running, the app monitors the clipboard to detect copied words or phrases. Only text matching the English word format is saved.
- To retrieve translations, phonetics, and definitions, words are sent to the online services Google Translate, MyMemory, and Free Dictionary API. Lookups may fail without an internet connection; words can still be saved, and the app will retry translations later.
- The app does not send web page content; saving is based only on text you copy.
