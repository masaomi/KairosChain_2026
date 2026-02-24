'use client';

import { useState, useEffect } from 'react';

interface TypewriterTextProps {
  text: string;
  speed?: number;
  onComplete?: () => void;
}

export default function TypewriterText({ text, speed = 30, onComplete }: TypewriterTextProps) {
  const [displayedText, setDisplayedText] = useState('');

  useEffect(() => {
    if (displayedText.length < text.length) {
      const timer = setTimeout(() => {
        setDisplayedText((prev) => prev + text[prev.length]);
      }, speed);

      return () => clearTimeout(timer);
    } else if (displayedText.length === text.length && text.length > 0) {
      onComplete?.();
    }
  }, [displayedText, text, speed, onComplete]);

  return (
    <span className="inline">
      {displayedText}
      {displayedText.length < text.length && <span className="animate-pulse">▌</span>}
    </span>
  );
}
