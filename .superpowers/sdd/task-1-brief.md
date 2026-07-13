### Task 1: Electron + Vite + React + TypeScript scaffold

**Files:**
- Create: `package.json`, `electron.vite.config.ts`, `tsconfig.json`, `tsconfig.node.json`, `tsconfig.web.json`
- Create: `src/main/index.ts`, `src/preload/index.ts`, `src/renderer/index.html`, `src/renderer/src/main.tsx`

**Interfaces:**
- Produces: Running Electron app showing a white window at `localhost` (dev) or bundled (prod)

- [ ] **Step 1: Scaffold with electron-vite**

```bash
cd "/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes"
npm create @quick-start/electron@latest . -- --template react-ts
```

Accept all defaults. This creates the full electron-vite boilerplate.

- [ ] **Step 2: Install dependencies**

```bash
npm install
npm install keytar uuid date-fns @radix-ui/react-dialog @radix-ui/react-scroll-area
npm install -D @types/uuid vitest @testing-library/react @testing-library/user-event jsdom @vitest/coverage-v8
```

- [ ] **Step 3: Add test config to `vite.config.ts` (renderer)**

In `electron.vite.config.ts`, add to the renderer config:
```typescript
renderer: {
  // existing config...
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/renderer/src/test-setup.ts'],
  }
}
```

Create `src/renderer/src/test-setup.ts`:
```typescript
import '@testing-library/jest-dom'
```

- [ ] **Step 4: Verify dev mode works**

```bash
npm run dev
```

Expected: Electron window opens showing the default Vite + React page.

- [ ] **Step 5: Commit**

```bash
git init
git add .
git commit -m "feat: scaffold Electron + Vite + React + TypeScript"
```

---
