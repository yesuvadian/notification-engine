import { Channel, ChannelAdapter } from './types.ts';
import { MockAdapter } from './mock.ts';

/** Picks the adapter for a channel from ntf_channels.provider_config.provider. */
export function adapterFor(channel: Channel, config: Record<string, unknown>): ChannelAdapter {
  const provider = String(config.provider ?? 'mock').toLowerCase();
  switch (`${channel}:${provider}`) {
    default:
      if (provider !== 'mock') throw new Error(`unsupported provider ${provider} for ${channel}`);
      return new MockAdapter(channel);
  }
}
