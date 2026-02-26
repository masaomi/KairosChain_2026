import { EchoMessage, ChatPartner } from '@/types';
import { Echo } from '@/types';

interface ChatMessageProps {
  message: EchoMessage;
  echo: Echo;
  partner?: ChatPartner;
}

export default function ChatMessage({ message, echo, partner = 'echo' }: ChatMessageProps) {
  const isUser = message.role === 'user';
  const isTiara = partner === 'tiara';

  if (isUser) {
    return (
      <div className="flex justify-end">
        <div className="max-w-xs lg:max-w-md glass-morphism rounded-2xl rounded-br-none p-4">
          <p className="text-[#f5f5f5]">{message.content}</p>
          <p className="text-xs text-[#b0b0b0] mt-2">
            {new Date(message.created_at).toLocaleTimeString('ja-JP', {
              hour: '2-digit',
              minute: '2-digit',
            })}
          </p>
        </div>
      </div>
    );
  }

  // Tiara message styling
  if (isTiara) {
    return (
      <div className="flex items-end gap-3">
        <div className="flex-shrink-0 w-8 h-8 rounded-full bg-gradient-to-br from-[#9b59b6] to-[#c0a0d0] flex items-center justify-center text-sm">
          🐱
        </div>
        <div className="max-w-xs lg:max-w-md bg-[#9b59b6]/10 border border-[#9b59b6]/30 rounded-2xl rounded-bl-none p-4">
          <p className="text-xs font-semibold text-[#c0a0d0] mb-1">ティアラ</p>
          <p className="text-[#f5f5f5] leading-relaxed">{message.content}</p>
          <p className="text-xs text-[#b0b0b0] mt-2">
            {new Date(message.created_at).toLocaleTimeString('ja-JP', {
              hour: '2-digit',
              minute: '2-digit',
            })}
          </p>
        </div>
      </div>
    );
  }

  // Echo/assistant message
  return (
    <div className="flex items-end gap-3">
      <div className="flex-shrink-0 w-8 h-8 rounded-full bg-gradient-to-br from-[#d4af37] to-[#50c878] flex items-center justify-center text-sm">
        💎
      </div>
      <div className="max-w-xs lg:max-w-md bg-[#d4af37]/10 border border-[#d4af37]/30 rounded-2xl rounded-bl-none p-4">
        <p className="text-xs font-semibold text-[#d4af37] mb-1">{echo.name}</p>
        <p className="text-[#f5f5f5]">{message.content}</p>
        <p className="text-xs text-[#b0b0b0] mt-2">
          {new Date(message.created_at).toLocaleTimeString('ja-JP', {
            hour: '2-digit',
            minute: '2-digit',
          })}
        </p>
      </div>
    </div>
  );
}
