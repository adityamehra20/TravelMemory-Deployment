// frontend/src/url.js
//
// Central place for the backend base URL. The value comes from the
// REACT_APP_BACKEND_URL environment variable defined in frontend/.env
// (see ../.env.example). React inlines this value at build time, so rebuild
// the frontend (`npm run build`) whenever you change it.
//
// Components import it like:  import { baseUrl } from "../url";
// and call:                   fetch(`${baseUrl}/trip`)

export const baseUrl = process.env.REACT_APP_BACKEND_URL;
