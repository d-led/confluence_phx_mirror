// Swagger UI for /api/docs/swagger.
//
// Its own bundle, not part of app.js: the reader pages must not pay for a
// vendor UI that only the API page uses, and `/api/docs` stays a plain
// server-rendered page with no JavaScript at all.
//
// The document it mounts is the one the server generates from the router, so
// "Try it out" sends its requests to this mirror. The URL travels in the
// container's `data-spec-url` rather than being spelled again here — the
// router owns the path, this file only renders it.
import SwaggerUIBundle from "swagger-ui-dist/swagger-ui-bundle.js"
import "swagger-ui-dist/swagger-ui.css"

const container = document.getElementById("swagger-ui")

if (container) {
  SwaggerUIBundle({
    url: container.dataset.specUrl,
    dom_id: "#swagger-ui",
    deepLinking: true,
    displayRequestDuration: true,
    // The mirror is usually reached through oauth2-proxy, which authenticates
    // the browser with its own cookie and forwards who it is. Sending cookies
    // means "Try it out" is already signed in; the Authorize dialog stays for
    // scripts, which have a token instead.
    withCredentials: true,
  })
}
