import { ReactNode } from 'react';
import clsx from 'clsx';

interface CardProps {
  children: ReactNode;
  className?: string;
}

export default function Card({ children, className }: CardProps) {
  return (
    <div
      className={clsx(
        'glass-morphism rounded-2xl p-6 sm:p-8',
        className
      )}
    >
      {children}
    </div>
  );
}
