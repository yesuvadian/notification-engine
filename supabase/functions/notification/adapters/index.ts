import { Channel, ChannelAdapter } from './types.ts';
import { MockAdapter } from './mock.ts';
import { TwilioSmsAdapter } from './twilio.ts';
import { Msg91SmsAdapter } from './msg91.ts';
import { MetaWhatsAppAdapter } from './whatsapp_meta.ts';
import { FcmPushAdapter } from './fcm.ts';
import { GenericHttpAdapter } from './http_generic.ts';

export const PROVIDERS: Record<Channel, string[]> = {
  IN_APP: ['mock'],
  SMS: ['mock', 'twilio', 'msg91', 'http'],
  WHATSAPP: ['mock', 'meta', 'http'],
  PUSH: ['mock', 'fcm']
};

/** Picks the adapter for a channel from ntf_channels.provider_config.provider (default: mock). */
export function adapterFor(channel: Channel, config: Record<string, unknown>): ChannelAdapter {
  const provider = String(config.provider ?? 'mock').toLowerCase();
  switch (`${channel}:${provider}`) {
    case 'SMS:twilio': return new TwilioSmsAdapter();
    case 'SMS:msg91': return new Msg91SmsAdapter();
    case 'WHATSAPP:meta': return new MetaWhatsAppAdapter();
    case 'PUSH:fcm': return new FcmPushAdapter();
    case 'SMS:http':
    case 'WHATSAPP:http': return new GenericHttpAdapter(channel);
    default:
      if (provider !== 'mock') throw new Error(`unsupported provider ${provider} for ${channel}`);
      return new MockAdapter(channel);
  }
}
