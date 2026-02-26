import Link from 'next/link';

export default function NotFound() {
  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] flex items-center justify-center px-4">
      <div className="glass-morphism rounded-2xl p-8 sm:p-12 text-center max-w-md">
        <div className="text-6xl mb-6 opacity-50">404</div>
        <h1 className="text-2xl font-serif text-[#d4af37] mb-4">
          この場所には、何もありません
        </h1>
        <p className="text-[#b0b0b0] mb-8 leading-relaxed">
          あなたが探しているものは、まだ名前を持っていないのかもしれません。
          呼応石の導きに従って、戻りましょう。
        </p>
        <Link
          href="/"
          className="inline-flex items-center gap-2 px-6 py-3 bg-[#d4af37] text-[#1a0a2e] font-semibold rounded-lg hover:bg-[#e8c547] transition-colors"
        >
          はじまりの場所へ
        </Link>
      </div>
    </div>
  );
}
