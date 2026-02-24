interface EchoAvatarProps {
  status?: 'embryo' | 'growing' | 'crystallized';
  size?: 'sm' | 'md' | 'lg';
}

export default function EchoAvatar({ status = 'embryo', size = 'md' }: EchoAvatarProps) {
  const sizeClasses = {
    sm: 'w-10 h-10 text-lg',
    md: 'w-16 h-16 text-3xl',
    lg: 'w-24 h-24 text-5xl',
  };

  const emoji = {
    embryo: '✨',
    growing: '🌟',
    crystallized: '💎',
  };

  const glowColor = {
    embryo: 'shadow-lg shadow-yellow-500/50',
    growing: 'shadow-lg shadow-blue-500/50',
    crystallized: 'shadow-lg shadow-purple-500/50',
  };

  return (
    <div
      className={`${sizeClasses[size]} rounded-full bg-gradient-to-br from-[#d4af37] to-[#50c878] flex items-center justify-center ${glowColor[status]} animate-float`}
    >
      {emoji[status]}
    </div>
  );
}
