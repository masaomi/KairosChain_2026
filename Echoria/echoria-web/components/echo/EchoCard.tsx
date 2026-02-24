import Link from 'next/link';
import { Echo } from '@/types';
import EchoAvatar from './EchoAvatar';
import PersonalityRadar from './PersonalityRadar';
import { BookOpen, MessageCircle } from 'lucide-react';

interface EchoCardProps {
  echo: Echo;
}

export default function EchoCard({ echo }: EchoCardProps) {
  const statusLabels: Record<string, string> = {
    embryo: '胚胎',
    growing: '成長中',
    crystallized: '結晶化',
  };

  const statusColor: Record<string, string> = {
    embryo: 'bg-yellow-500/20 text-yellow-200 border-yellow-500/30',
    growing: 'bg-blue-500/20 text-blue-200 border-blue-500/30',
    crystallized: 'bg-purple-500/20 text-purple-200 border-purple-500/30',
  };

  return (
    <Link href={`/echo/${echo.id}`} className="group">
      <div className="glass-morphism rounded-2xl p-6 sm:p-8 min-h-96 flex flex-col hover:bg-white/10 transition-all duration-200 h-full">
        {/* Header */}
        <div className="flex items-start justify-between mb-6">
          <div className="flex-1">
            <h3 className="text-2xl font-serif font-bold text-[#d4af37] mb-2 group-hover:text-[#e8c547] transition-colors">
              {echo.name}
            </h3>
            <span className={`inline-block text-xs font-semibold px-3 py-1 rounded-full border ${statusColor[echo.status]}`}>
              {statusLabels[echo.status]}
            </span>
          </div>

          <EchoAvatar status={echo.status} size="md" />
        </div>

        {/* Stats */}
        <div className="grid grid-cols-3 gap-4 mb-6 text-center">
          <div>
            <p className="text-xs text-[#b0b0b0] mb-1">進捗</p>
            <p className="text-lg font-bold text-[#50c878]">{echo.storyProgress || 0}%</p>
          </div>
          <div>
            <p className="text-xs text-[#b0b0b0] mb-1">モーメント</p>
            <p className="text-lg font-bold text-[#d4af37]">{echo.keyMoments?.length || 0}</p>
          </div>
          <div>
            <p className="text-xs text-[#b0b0b0] mb-1">ティアラ</p>
            <p className="text-lg font-bold text-[#50c878]">
              {Math.round((echo.affinity?.tiaraAffinity || 0) * 100)}%
            </p>
          </div>
        </div>

        {/* Personality Radar */}
        <div className="mb-6 flex justify-center">
          <div className="w-40 h-40">
            <PersonalityRadar affinity={echo.affinity} size="sm" />
          </div>
        </div>

        {/* Action Buttons */}
        <div className="flex gap-3 mt-auto pt-6 border-t border-white/10">
          <Link
            href={`/echo/${echo.id}/story`}
            className="flex-1 flex items-center justify-center gap-2 px-4 py-2 rounded-lg bg-[#d4af37]/20 text-[#d4af37] hover:bg-[#d4af37]/30 transition-colors text-sm font-semibold"
          >
            <BookOpen className="w-4 h-4" />
            <span>物語</span>
          </Link>

          {echo.status === 'crystallized' && (
            <Link
              href={`/echo/${echo.id}/chat`}
              className="flex-1 flex items-center justify-center gap-2 px-4 py-2 rounded-lg bg-[#50c878]/20 text-[#50c878] hover:bg-[#50c878]/30 transition-colors text-sm font-semibold"
            >
              <MessageCircle className="w-4 h-4" />
              <span>チャット</span>
            </Link>
          )}
        </div>
      </div>
    </Link>
  );
}
