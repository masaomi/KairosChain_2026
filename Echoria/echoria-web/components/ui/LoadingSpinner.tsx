export default function LoadingSpinner() {
  return (
    <div className="flex flex-col items-center justify-center gap-4">
      <div className="relative w-16 h-16">
        {/* Outer ring */}
        <div className="absolute inset-0 rounded-full border-4 border-[#d4af37]/20" />

        {/* Animated ring */}
        <div
          className="absolute inset-0 rounded-full border-4 border-transparent border-t-[#d4af37] border-r-[#50c878] animate-spin"
          style={{
            animation: 'spin 2s linear infinite',
          }}
        />

        {/* Center dot */}
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="w-3 h-3 rounded-full bg-[#d4af37]" />
        </div>
      </div>
      <p className="text-[#b0b0b0] text-sm animate-pulse">読み込み中...</p>
    </div>
  );
}
