interface TiaraAvatarProps {
  trust?: number; // 0 to 1
  size?: 'sm' | 'md' | 'lg';
}

export default function TiaraAvatar({ trust = 0.5, size = 'md' }: TiaraAvatarProps) {
  const getExpression = () => {
    if (trust < 0.3) return '😿'; // sad
    if (trust < 0.5) return '😐'; // concerned
    if (trust < 0.75) return '😺'; // curious
    return '😸'; // happy
  };

  const sizeClasses = {
    sm: 'w-8 h-8 text-lg',
    md: 'w-10 h-10 text-xl',
    lg: 'w-12 h-12 text-2xl',
  };

  return (
    <div
      className={`${sizeClasses[size]} rounded-full bg-gradient-to-br from-[#50c878] to-[#3ba864] flex items-center justify-center shadow-lg shadow-[#50c878]/50 glow-emerald`}
    >
      {getExpression()}
    </div>
  );
}
