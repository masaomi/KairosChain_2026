'use client';

import { useState } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Menu, X, Settings, LogOut } from 'lucide-react';
import { removeToken } from '@/lib/auth';

export default function Header() {
  const [isMenuOpen, setIsMenuOpen] = useState(false);
  const pathname = usePathname();

  const isHome = pathname === '/home';
  const isAuth = pathname === '/login' || pathname === '/signup';

  if (isAuth) {
    return null;
  }

  const handleLogout = () => {
    removeToken();
    window.location.href = '/';
  };

  return (
    <header className="border-b border-white/10 bg-black/20 backdrop-blur-md sticky top-0 z-40">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
        <div className="flex items-center justify-between">
          {/* Logo */}
          <Link href={isHome ? '/home' : '/'} className="flex items-center gap-2">
            <span className="text-2xl font-serif font-bold text-gradient">Echoria</span>
          </Link>

          {/* Desktop Navigation */}
          <nav className="hidden md:flex items-center gap-8">
            {isHome && (
              <>
                <Link href="/home" className="text-[#f5f5f5] hover:text-[#d4af37] transition-colors text-sm">
                  ダッシュボード
                </Link>
                <Link href="/settings" className="text-[#f5f5f5] hover:text-[#d4af37] transition-colors text-sm">
                  設定
                </Link>
              </>
            )}
          </nav>

          {/* Desktop User Menu */}
          {isHome && (
            <div className="hidden md:flex items-center gap-4">
              <Link
                href="/settings"
                className="p-2 rounded-lg hover:bg-white/10 transition-colors text-[#d4af37]"
                title="設定"
              >
                <Settings className="w-5 h-5" />
              </Link>
              <button
                onClick={handleLogout}
                className="p-2 rounded-lg hover:bg-white/10 transition-colors text-[#d4af37]"
                title="ログアウト"
              >
                <LogOut className="w-5 h-5" />
              </button>
            </div>
          )}

          {/* Mobile Menu Button */}
          <button
            onClick={() => setIsMenuOpen(!isMenuOpen)}
            className="md:hidden p-2 rounded-lg hover:bg-white/10 transition-colors text-[#d4af37]"
          >
            {isMenuOpen ? (
              <X className="w-6 h-6" />
            ) : (
              <Menu className="w-6 h-6" />
            )}
          </button>
        </div>

        {/* Mobile Navigation */}
        {isMenuOpen && isHome && (
          <nav className="md:hidden mt-4 pt-4 border-t border-white/10 space-y-3">
            <Link
              href="/home"
              className="block text-[#f5f5f5] hover:text-[#d4af37] transition-colors py-2"
              onClick={() => setIsMenuOpen(false)}
            >
              ダッシュボード
            </Link>
            <Link
              href="/settings"
              className="block text-[#f5f5f5] hover:text-[#d4af37] transition-colors py-2"
              onClick={() => setIsMenuOpen(false)}
            >
              設定
            </Link>
            <button
              onClick={() => {
                handleLogout();
                setIsMenuOpen(false);
              }}
              className="block w-full text-left text-[#f5f5f5] hover:text-[#d4af37] transition-colors py-2"
            >
              ログアウト
            </button>
          </nav>
        )}
      </div>
    </header>
  );
}
