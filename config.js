/**
 * FinSphere — Connection Config
 * ---------------------------------
 * Paste your deployed Google Apps Script Web App URL below, between
 * the quotes. Do this ONCE. After that, every device that opens this
 * app (or a copy of this folder you share) connects automatically —
 * nobody else needs to know or paste the link.
 *
 * Where to get this URL:
 *   Google Sheet → Extensions → Apps Script → paste AppsScript.gs.txt
 *   → Deploy → New deployment → Web app → Execute as: Me,
 *   Who has access: Anyone with the link → Deploy → copy the URL.
 *
 * To change the database later (e.g. redeployed a new version),
 * just edit this line and re-share the file. The app uses this value
 * automatically and does not require any manual setup for normal users.
 */
const DEFAULT_SCRIPT_URL = "https://script.google.com/macros/s/AKfycby4XKK2I411Ln9WwvAsbUn4EFmE31AFnvy5TO4MhuVBT9UaTQzNAtLEkH4q3fSsR1V9/exec";

/**
 * Google Sign-In — identity only, for now.
 * ------------------------------------------
 * This just shows who's using the app ("Hi <name>" in the header) —
 * it does NOT restrict who can open or use anything yet. Access
 * control by account can be added later on top of this.
 *
 * To turn it on: create a free OAuth Client ID at
 *   https://console.cloud.google.com/ → APIs & Services → Credentials
 *   → Create Credentials → OAuth client ID → Web application →
 *   add your hosted app's URL under "Authorized JavaScript origins"
 *   → Create → paste the Client ID below.
 * Leave the placeholder as-is to keep sign-in switched off.
 */
const GOOGLE_CLIENT_ID = "PASTE_YOUR_GOOGLE_OAUTH_CLIENT_ID_HERE.apps.googleusercontent.com";
