// html`...`: htm bound to React (vendored, no build step). Components import this and the hooks.
import htm from "../vendor/htm.module.js";

const React = window.React;
export const html = htm.bind(React.createElement);
export const { useState, useEffect, useRef, useMemo, useCallback, Fragment } = React;
