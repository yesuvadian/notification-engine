import { Channel, ChannelAdapter, SendRequest, SendResult } from './types.ts';

/** Used when a channel has no provider configured (DEV). ACCEPTED is not proof of delivery. */
export class MockAdapter implements ChannelAdapter {
  readonly provider = 'mock';
  constructor(readonly channel: Channel) {}
  send(req: SendRequest): Promise<SendResult> {
    return Promise.resolve({ outcome: 'ACCEPTED', providerMessageId: `mock-${req.deliveryId}`, response: { mock: true } });
  }
}
