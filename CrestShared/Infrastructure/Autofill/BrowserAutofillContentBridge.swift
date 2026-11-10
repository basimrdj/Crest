import Foundation

/// Script and message handler definitions for native form autofill.
/// Runs in an isolated world on WebKit and Chromium engines.
@MainActor
public enum BrowserAutofillContentBridge {
    public static let messageHandlerName = "crestAutofill"

    public static let source = #"""
        (() => {
          "use strict";
          if (globalThis.__crestAutofillBridge) return;

          const handler = webkit.messageHandlers.crestAutofill;
          const formsByID = new Map();
          let nextFormID = 1;

          const post = (body) => {
            try { handler.postMessage({ version: 1, ...body }); } catch (_) {}
          };

          const isVisible = (element) => {
            if (!(element instanceof HTMLInputElement || element instanceof HTMLSelectElement || element instanceof HTMLTextAreaElement)) return false;
            if (element.disabled || element.readOnly) return false;
            const style = getComputedStyle(element);
            if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          };

          const rectOf = (element) => {
            const rect = element.getBoundingClientRect();
            if (!(rect.width > 0) || !(rect.height > 0)) return null;
            return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
          };

          const normalizeToken = (token) => (token || "").toLowerCase().trim();

          // Classifies what identity property an input represents
          const classifyField = (input) => {
            if (input.type === "password" || input.type === "hidden" || input.type === "file" || input.type === "submit") {
              return null;
            }

            const rawAutocomplete = normalizeToken(input.getAttribute("autocomplete"));
            if (rawAutocomplete === "off" || rawAutocomplete === "new-password" || rawAutocomplete === "current-password" || rawAutocomplete === "one-time-code") {
              return null;
            }

            // Split into distinct tokens to prevent substring false-positives (e.g. cc-name, nickname)
            const tokens = rawAutocomplete.split(/\s+/);

            // Exclude payment / card tokens explicitly (fail closed to address/identity scope)
            if (tokens.some(t => t.startsWith("cc-") || t.startsWith("transaction-") || t === "csc" || t === "cvv")) {
              return null;
            }

            // Standard HTML autocomplete tokens (exact token matching)
            if (tokens.includes("name")) return "fullName";
            if (tokens.includes("given-name")) return "givenName";
            if (tokens.includes("family-name")) return "familyName";
            if (tokens.includes("additional-name")) return "middleName";
            if (tokens.includes("organization")) return "organization";
            if (tokens.includes("email") || input.type === "email") return "email";
            if (tokens.includes("tel") || input.type === "tel") return "phoneNumber";
            if (tokens.includes("street-address") || tokens.includes("address-line1")) return "streetAddress";
            if (tokens.includes("address-line2")) return "addressLine2";
            if (tokens.includes("address-level2")) return "city";
            if (tokens.includes("address-level1")) return "stateOrProvince";
            if (tokens.includes("postal-code")) return "postalCode";
            if (tokens.includes("country") || tokens.includes("country-name")) return "countryOrRegion";

            // Fallback heuristics based on name/id attributes
            const identifier = `${input.name || ""} ${input.id || ""} ${input.placeholder || ""}`.toLowerCase();
            if (/\b(zip|postal|postcode|pincode)\b/.test(identifier)) return "postalCode";
            if (/\b(city|town|suburb)\b/.test(identifier)) return "city";
            if (/\b(state|province|region)\b/.test(identifier)) return "stateOrProvince";
            if (/\b(country)\b/.test(identifier)) return "countryOrRegion";
            if (/\b(address|street|addr1)\b/.test(identifier)) return "streetAddress";
            if (/\b(addr2|apt|suite|unit)\b/.test(identifier)) return "addressLine2";
            if (/\b(first.*name|fname|given.*name)\b/.test(identifier)) return "givenName";
            if (/\b(last.*name|lname|surname|family.*name)\b/.test(identifier)) return "familyName";
            if (/\b(full.*name|your.*name)\b/.test(identifier)) return "fullName";
            if (/\b(company|org|organization)\b/.test(identifier)) return "organization";
            if (/\b(phone|mobile|telephone|cell)\b/.test(identifier)) return "phoneNumber";
            if (/\b(email|e-mail)\b/.test(identifier)) return "email";

            return null;
          };

          const formRootFor = (element) => {
            if (element.form) return element.form;
            return element.closest("form, [role='form']") || element.getRootNode();
          };

          const idForForm = (root) => {
            for (const [id, ref] of formsByID) {
              if (ref.deref() === root) return id;
            }
            const id = `autofill-form-${nextFormID++}`;
            formsByID.set(id, new WeakRef(root));
            return id;
          };

          const setElementValue = (element, value) => {
            if (!element || value == null) return;
            const prototype = element instanceof HTMLInputElement ? HTMLInputElement.prototype
              : element instanceof HTMLSelectElement ? HTMLSelectElement.prototype
              : HTMLTextAreaElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
            if (setter) setter.call(element, value); else element.value = value;
            element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertReplacementText", data: null }));
            element.dispatchEvent(new Event("change", { bubbles: true }));
          };

          const handleFocus = (element) => {
            if (!isVisible(element)) return;
            const fieldType = classifyField(element);
            if (!fieldType) return;

            const root = formRootFor(element);
            const formID = idForForm(root);
            const rect = rectOf(element);

            post({
              event: "focus",
              fieldType,
              formID,
              fieldRect: rect || undefined
            });
          };

          globalThis.__crestAutofillBridge = Object.freeze({
            fill(formID, values) {
              const root = formsByID.get(formID)?.deref();
              if (!root || !root.isConnected) return false;

              const inputs = Array.from(root.querySelectorAll("input, select, textarea")).filter(isVisible);
              let filledCount = 0;

              for (const input of inputs) {
                const kind = classifyField(input);
                if (kind && values[kind] !== undefined && values[kind] !== "") {
                  setElementValue(input, values[kind]);
                  filledCount++;
                }
              }
              return filledCount > 0;
            }
          });

          document.addEventListener("focusin", (event) => {
            if (!event.isTrusted) return;
            const target = event.target;
            if (target instanceof HTMLInputElement || target instanceof HTMLSelectElement || target instanceof HTMLTextAreaElement) {
              handleFocus(target);
            }
          }, true);

          document.addEventListener("focusout", (event) => {
            if (!event.isTrusted) return;
            const target = event.target;
            if (target instanceof HTMLInputElement || target instanceof HTMLSelectElement || target instanceof HTMLTextAreaElement) {
              const root = formRootFor(target);
              const formID = idForForm(root);
              post({ event: "blur", formID });
            }
          }, true);
        })();
        """#
}
