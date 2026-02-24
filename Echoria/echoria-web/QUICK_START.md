# Echoria Web - Quick Start Guide

## Installation & Setup

```bash
# Navigate to project directory
cd /sessions/optimistic-focused-davinci/mnt/KairosChain_2026/Echoria/echoria-web

# Install dependencies
npm install

# Set up environment
echo "NEXT_PUBLIC_API_URL=http://localhost:3001/api" > .env.local

# Start development server
npm run dev
```

Visit http://localhost:3000

## Project Layout

### Pages (User-Facing)
| Page | Path | Authentication | Purpose |
|------|------|---|---------|
| Landing | `/` | No | Hero section, sign up/login CTA |
| Login | `/login` | No | Email/password authentication |
| Signup | `/signup` | No | User registration |
| Dashboard | `/home` | Yes | View and create Echoes |
| Echo Profile | `/echo/{id}` | Yes | View Echo details and personality |
| Story | `/echo/{id}/story` | Yes | Visual novel narrative interface |
| Chat | `/echo/{id}/chat` | Yes | AI conversation (crystallized only) |
| Settings | `/settings` | Yes | Account and app settings |
| Terms | `/terms` | No | Terms of service |
| Privacy | `/privacy` | No | Privacy policy |

### Component Hierarchy

```
Header (top navigation)
├── Landing Page
├── Auth Pages (Login/Signup)
├── Protected Pages (AuthGuard wrapper)
│   ├── Dashboard
│   │   └── EchoCard[]
│   ├── Echo Profile
│   │   ├── EchoAvatar
│   │   ├── PersonalityRadar
│   │   └── KeyMoments
│   ├── Story
│   │   ├── StoryScene
│   │   ├── TiaraAvatar
│   │   └── ChoicePanel
│   └── Chat
│       ├── ChatMessage[]
│       └── ChatInput
└── Legal Pages (Terms/Privacy)
```

## File Locations Guide

### Want to modify...

**Colors/Theme?**
→ `/app/globals.css` (CSS variables at :root)
→ `tailwind.config` in globals.css

**Page Layout?**
→ `/app/[page]/page.tsx`

**Component Styling?**
→ Component file (Tailwind classes inline)
→ `/app/globals.css` (if using custom classes)

**API Endpoints?**
→ `/lib/api.ts` (all API methods)

**Type Definitions?**
→ `/types/index.ts`

**Navigation?**
→ `/components/layout/Header.tsx`

**Story Logic?**
→ `/app/echo/[id]/story/page.tsx` (main logic)
→ `/components/story/` (sub-components)

**Chat Interface?**
→ `/app/echo/[id]/chat/page.tsx`
→ `/components/chat/` (sub-components)

## Common Tasks

### Add a New Page

1. Create `/app/new-page/page.tsx`
```typescript
'use client';

import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';

function NewPageContent() {
  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460]">
      <Header />
      <main className="max-w-4xl mx-auto px-4 py-8">
        {/* Content */}
      </main>
    </div>
  );
}

export default function NewPage() {
  return (
    <AuthGuard>
      <NewPageContent />
    </AuthGuard>
  );
}
```

2. Add to Header navigation if needed

### Modify Theme Colors

Edit `/app/globals.css` (root CSS variables):
```css
:root {
  --color-bg-primary: #1a0a2e;
  --color-accent-gold: #d4af37;
  /* etc */
}
```

Then use in Tailwind: `bg-[#1a0a2e]`

### Add API Method

1. Add to `/lib/api.ts`:
```typescript
async myNewMethod(param: string): Promise<ResponseType> {
  return this.request('/endpoint', {
    method: 'POST',
    body: JSON.stringify({ param }),
  });
}
```

2. Export: `export const myNewMethod = (param: string) => apiClient.myNewMethod(param);`

### Add Component Variant

Use CVA (class-variance-authority) in Button component:
```typescript
const buttonVariants = cva('base-styles', {
  variants: {
    variant: {
      newVariant: 'styles-for-variant'
    }
  }
});
```

## Styling Patterns

### Colors
- Background: `bg-[#1a0a2e]`
- Gold accent: `text-[#d4af37]`
- Emerald (Tiara): `text-[#50c878]`
- Text: `text-[#f5f5f5]`
- Muted: `text-[#b0b0b0]`

### Layout
- Container: `max-w-4xl mx-auto px-4`
- Flexbox: `flex items-center justify-between`
- Grid: `grid grid-cols-1 md:grid-cols-2 gap-6`

### Cards
- Glass effect: `glass-morphism rounded-2xl p-6 sm:p-8`

### Buttons
- Primary: `button-primary px-6 py-3`
- Secondary: `button-secondary px-6 py-3`
- Ghost: `button-ghost px-6 py-3`

### Responsive
- Mobile: `text-sm sm:text-base lg:text-lg`
- Padding: `px-4 sm:px-6 lg:px-8`
- Grid: `grid-cols-1 md:grid-cols-2 lg:grid-cols-3`

## Authentication Flow

```
User visits /login or /signup
    ↓
Submits email/password
    ↓
API returns { token, user }
    ↓
setToken() stores in localStorage
    ↓
Redirect to /home
    ↓
AuthGuard checks isAuthenticated()
    ↓
Renders protected content
```

## Testing Auth

```typescript
// Check if authenticated
isAuthenticated() // returns boolean

// Manual testing in browser console
localStorage.setItem('echoria_token', 'test_token')
localStorage.getItem('echoria_token')
```

## Environment Variables

Only one variable needed (in `.env.local`):
```
NEXT_PUBLIC_API_URL=http://localhost:3001/api
```

Accessible in code as:
```typescript
const url = process.env.NEXT_PUBLIC_API_URL
```

## Build & Deploy

```bash
# Build for production (static export)
npm run build

# Output goes to /out directory
# Can be deployed to any static hosting

# For local testing:
npm run start
```

## Debugging Tips

### Console Errors
- Check Network tab for API failures
- Verify NEXT_PUBLIC_API_URL is correct
- Check token with: `localStorage.getItem('echoria_token')`

### Styling Issues
- Use browser DevTools to inspect Tailwind classes
- Remember responsive prefixes: `sm:`, `md:`, `lg:`
- Check globals.css for theme variables

### Component Issues
- Verify props match TypeScript types
- Check imports use correct paths (`@/...`)
- Ensure 'use client' is at top of client components

### API Issues
- Check backend is running on correct port
- Verify endpoint URLs in `/lib/api.ts`
- Monitor Network tab in DevTools
- Check CORS configuration on backend

## Directory Tree

```
echoria-web/
├── app/                        # Pages & layouts
│   ├── echo/[id]/
│   │   ├── page.tsx
│   │   ├── story/page.tsx
│   │   └── chat/page.tsx
│   ├── globals.css
│   ├── layout.tsx
│   └── page.tsx
├── components/                 # React components
│   ├── chat/
│   ├── echo/
│   ├── layout/
│   ├── story/
│   └── ui/
├── lib/                        # Utilities
│   ├── api.ts
│   └── auth.ts
├── types/                      # TypeScript
│   └── index.ts
├── public/                     # Static assets
├── .env.local                  # Your environment vars
├── next.config.js
├── package.json
├── postcss.config.js
├── tsconfig.json
└── README.md
```

## Resources

- **Next.js Docs**: https://nextjs.org/docs
- **React Docs**: https://react.dev
- **Tailwind CSS**: https://tailwindcss.com/docs
- **TypeScript**: https://www.typescriptlang.org/docs

## Support

For issues:
1. Check README.md for full documentation
2. Review IMPLEMENTATION_SUMMARY.md for architecture
3. Check component files for examples
4. Review types/index.ts for data structures
