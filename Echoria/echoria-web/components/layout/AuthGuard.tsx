'use client';

import { useEffect, ReactNode } from 'react';
import { useRouter, usePathname } from 'next/navigation';
import { isAuthenticated } from '@/lib/auth';

export default function AuthGuard({ children }: { children: ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();

  useEffect(() => {
    if (!isAuthenticated()) {
      router.push(`/login?redirect=${encodeURIComponent(pathname)}`);
    }
  }, [router, pathname]);

  if (!isAuthenticated()) {
    return null;
  }

  return <>{children}</>;
}
