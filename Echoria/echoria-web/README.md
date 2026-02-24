# Echoria Web Frontend

A narrative-driven AI app where users guide their "Echo" (AI persona) through interactive stories with a cat spirit companion named Tiara.

## Technology Stack

- **Framework**: Next.js 16 with React 19
- **Language**: TypeScript 5
- **Styling**: Tailwind CSS 4 with custom dark fantasy theme
- **Components**: Radix UI, Lucide React icons
- **Build**: Static export (output: 'export')

## Design Theme

Dark fantasy aesthetic with the following color palette:
- **Background**: Deep purple (#1a0a2e)
- **Secondary**: Dark blue (#16213e)
- **Accent Gold**: #d4af37
- **Tiara/Emerald**: #50c878
- **Text Primary**: Soft white (#f5f5f5)
- **Text Secondary**: Light gray (#b0b0b0)

**Fonts**:
- **UI**: Inter (400, 500, 600, 700)
- **Story Text**: Noto Serif JP (serif font for narrative immersion)

## Project Structure

```
echoria-web/
├── app/                          # Next.js app directory
│   ├── layout.tsx               # Root layout with metadata
│   ├── globals.css              # Global styles + Tailwind config
│   ├── page.tsx                 # Landing page
│   ├── login/page.tsx           # Login form
│   ├── signup/page.tsx          # Signup form
│   ├── home/page.tsx            # Dashboard (authenticated)
│   ├── echo/
│   │   └── [id]/
│   │       ├── page.tsx         # Echo profile page
│   │       ├── story/page.tsx   # Story UI (visual novel style)
│   │       └── chat/page.tsx    # Post-crystallization chat
│   ├── settings/page.tsx        # User settings
│   ├── terms/page.tsx           # Terms of service
│   └── privacy/page.tsx         # Privacy policy
├── components/
│   ├── layout/
│   │   ├── Header.tsx           # App header with nav
│   │   └── AuthGuard.tsx        # Protected route wrapper
│   ├── ui/
│   │   ├── Button.tsx           # Reusable button component
│   │   ├── Card.tsx             # Glass-morphism card
│   │   ├── LoadingSpinner.tsx   # Animated loader
│   │   └── TypewriterText.tsx   # Typewriter effect
│   ├── story/
│   │   ├── StoryScene.tsx       # Scene display component
│   │   ├── ChoicePanel.tsx      # Choice buttons
│   │   ├── TiaraAvatar.tsx      # Tiara spirit avatar
│   │   └── AffinityIndicator.tsx # Affinity change animation
│   ├── echo/
│   │   ├── EchoCard.tsx         # Echo summary card
│   │   ├── PersonalityRadar.tsx # 5-axis radar chart (SVG)
│   │   └── EchoAvatar.tsx       # Echo avatar
│   └── chat/
│       ├── ChatMessage.tsx      # Message bubble
│       └── ChatInput.tsx        # Message input with auto-resize
├── lib/
│   ├── api.ts                   # API client with JWT management
│   └── auth.ts                  # Auth helpers (localStorage)
├── types/
│   └── index.ts                 # TypeScript interfaces
├── public/
│   └── favicon.ico              # (add separately)
├── package.json                 # Dependencies
├── tsconfig.json                # TypeScript config
├── next.config.js               # Next.js config (static export)
├── postcss.config.js            # PostCSS config for Tailwind
└── .eslintrc.json               # ESLint config
```

## Features

### Authentication
- Email/password login and signup
- Google OAuth integration (placeholder)
- JWT token stored in localStorage
- AuthGuard component for protected routes

### Echo Management
- Create and manage AI personas
- Three status levels: embryo, growing, crystallized
- 5-axis personality radar (courage, wisdom, compassion, ambition, curiosity)
- Story progress tracking

### Story System
- Visual novel-style narrative UI
- Typewriter effect for text animation
- Tiara (cat spirit) dialogue system
- Choice buttons with consequences
- Echo auto-decision option
- Affinity change indicators
- Atmospheric background changes based on scene mood

### Chat System
- Available after Echo reaches "crystallized" status
- Real-time message display
- Auto-expanding textarea input
- Different message styling for user, Echo, and Tiara

### Responsive Design
- Mobile-first approach
- Breakpoints: sm (640px), md (768px), lg (1024px)
- Hamburger menu on mobile
- Touch-friendly buttons and inputs

## Installation

```bash
# Install dependencies
npm install

# Run development server
npm run dev

# Build for production (static export)
npm run build

# Start production server
npm start

# Type checking
npm run type-check

# Linting
npm run lint
```

## Environment Variables

Create a `.env.local` file in the project root:

```env
NEXT_PUBLIC_API_URL=http://localhost:3001/api
```

## API Integration

The `/lib/api.ts` file provides a centralized API client with:
- Automatic JWT token injection
- 401 redirect to login on auth failure
- Error handling and user-friendly messages
- Endpoints for:
  - Authentication (login, signup, googleAuth)
  - Echo management (CRUD)
  - Story generation and choice submission
  - Chat messages
  - Conversation history

### Expected API Responses

The backend should return responses in this format:

```typescript
{
  token: "jwt_token_string",
  user: { id, name, email, createdAt, updatedAt }
}
```

## Styling

### Color Utilities
- Use `text-[#d4af37]` for gold accents
- Use `text-[#50c878]` for Tiara emerald
- Use `text-[#f5f5f5]` for primary text
- Use `text-[#b0b0b0]` for secondary text

### Component Classes
- `.glass-morphism` - Frosted glass effect
- `.button-primary` - Gold button
- `.button-secondary` - Outline button
- `.button-ghost` - Text button
- `.story-text` - Serif font for narrative
- `.glow-emerald` - Emerald glow shadow
- `.glow-gold` - Gold glow shadow

### Animations
- `.animate-typewriter` - Character-by-character reveal
- `.animate-sparkle` - Affinity change sparkle
- `.animate-float` - Floating element
- `.animate-pulse-slow` - Slow pulse effect

## TypeScript Types

All major data structures are defined in `/types/index.ts`:
- `User` - User account info
- `Echo` - AI persona data
- `Affinity` - 5-axis personality metrics
- `StoryScene` - Narrative content
- `Choice` - Story choice object
- `EchoMessage` - Chat message
- `EchoConversation` - Conversation history

## Performance Considerations

- Static export eliminates server-side rendering overhead
- Client-side JWT management avoids server dependencies
- Lazy loading of Echo/story components
- Optimized images (currently unoptimized for static export)
- CSS-in-JS via Tailwind (compiled to static CSS)

## Security Notes

- JWT tokens stored in localStorage (vulnerable to XSS)
- For production, consider:
  - HttpOnly cookies instead of localStorage
  - CORS configuration
  - Rate limiting on auth endpoints
  - HTTPS enforcement
  - Content Security Policy headers

## Browser Support

- Modern browsers (Chrome, Firefox, Safari, Edge)
- Requires ES2020+ JavaScript support
- CSS Grid and Flexbox support
- SVG support for personality radar

## Future Enhancements

- Real-time WebSocket support for chat
- Multiplayer story experiences
- Advanced customization for Echo appearance
- Sound effects and background music
- Save/load story states
- Achievement system
- Seasonal events and storylines

## License

Proprietary - Echoria Project (2026)
