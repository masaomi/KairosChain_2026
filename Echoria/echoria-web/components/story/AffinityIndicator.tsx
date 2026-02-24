'use client';

import { useEffect, useState } from 'react';

interface AffinityIndicatorProps {
  axis: string;
  change: number;
}

export default function AffinityIndicator({ axis, change }: AffinityIndicatorProps) {
  const [show, setShow] = useState(true);

  useEffect(() => {
    const timer = setTimeout(() => {
      setShow(false);
    }, 2000);

    return () => clearTimeout(timer);
  }, []);

  if (!show) return null;

  return (
    <div className="animate-sparkle absolute top-0 right-0 pointer-events-none">
      <span className={`text-sm font-bold ${change > 0 ? 'text-[#50c878]' : 'text-red-400'}`}>
        {change > 0 ? '+' : ''}{change}
      </span>
    </div>
  );
}
