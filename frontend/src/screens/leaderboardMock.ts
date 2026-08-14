/**
 * Sample standings data for the leaderboard mock. Everything here is
 * hardcoded and deterministic, no contract reads, no randomness at
 * render time. Three periods (all time, season, week) are separate,
 * hand authored datasets so switching the segmented control actually
 * changes the numbers instead of just relabeling the same rows.
 */

export type LeaderboardPeriod = 'allTime' | 'season' | 'week'

export interface PeriodStats {
  wins: number
  losses: number
  streak: string
}

export interface RosterEntry {
  callsign: string
  address: string
  isYou?: boolean
  allTime: PeriodStats
  season: PeriodStats
  week: PeriodStats
}

export interface StandingRow extends PeriodStats {
  rank: number
  callsign: string
  address: string
  isYou: boolean
  winRate: number
}

export const ROSTER: RosterEntry[] = [
  {
    callsign: 'NIGHTJAR',
    address: '0x4a12...9e31',
    allTime: { wins: 58, losses: 14, streak: 'W6' },
    season: { wins: 21, losses: 5, streak: 'W6' },
    week: { wins: 4, losses: 0, streak: 'W4' },
  },
  {
    callsign: 'DRIFTWOOD',
    address: '0x7c88...2f04',
    allTime: { wins: 54, losses: 16, streak: 'W3' },
    season: { wins: 19, losses: 6, streak: 'W2' },
    week: { wins: 3, losses: 1, streak: 'L1' },
  },
  {
    callsign: 'ABYSSAL',
    address: '0x1e4f...b8a2',
    allTime: { wins: 51, losses: 19, streak: 'W2' },
    season: { wins: 18, losses: 7, streak: 'W1' },
    week: { wins: 3, losses: 1, streak: 'W1' },
  },
  {
    callsign: 'MERIDIAN',
    address: '0x9d33...c716',
    allTime: { wins: 49, losses: 20, streak: 'L1' },
    season: { wins: 17, losses: 8, streak: 'L1' },
    week: { wins: 2, losses: 1, streak: 'L1' },
  },
  {
    callsign: 'SALTWIRE',
    address: '0x2b76...4d90',
    allTime: { wins: 47, losses: 22, streak: 'W1' },
    season: { wins: 16, losses: 8, streak: 'W1' },
    week: { wins: 2, losses: 2, streak: 'L2' },
  },
  {
    callsign: 'LODESTONE',
    address: '0x6f01...aa55',
    allTime: { wins: 45, losses: 24, streak: 'W2' },
    season: { wins: 15, losses: 9, streak: 'W2' },
    week: { wins: 3, losses: 2, streak: 'W1' },
  },
  {
    callsign: 'KESTREL',
    address: '0x83e2...17c9',
    isYou: true,
    allTime: { wins: 43, losses: 25, streak: 'L2' },
    season: { wins: 14, losses: 9, streak: 'L2' },
    week: { wins: 2, losses: 2, streak: 'L2' },
  },
  {
    callsign: 'GANNET',
    address: '0x0c5a...6b3e',
    allTime: { wins: 41, losses: 27, streak: 'W1' },
    season: { wins: 13, losses: 10, streak: 'W1' },
    week: { wins: 2, losses: 2, streak: 'W1' },
  },
  {
    callsign: 'BLACKREEF',
    address: '0x55d8...f120',
    allTime: { wins: 39, losses: 28, streak: 'W4' },
    season: { wins: 13, losses: 10, streak: 'W3' },
    week: { wins: 3, losses: 1, streak: 'W3' },
  },
  {
    callsign: 'TIDEBORNE',
    address: '0xa914...73dc',
    allTime: { wins: 38, losses: 30, streak: 'L1' },
    season: { wins: 12, losses: 11, streak: 'L1' },
    week: { wins: 1, losses: 2, streak: 'L1' },
  },
  {
    callsign: 'DEEPCHART',
    address: '0x8f2a...c419',
    allTime: { wins: 36, losses: 31, streak: 'W2' },
    season: { wins: 12, losses: 11, streak: 'W2' },
    week: { wins: 2, losses: 1, streak: 'W2' },
  },
  {
    callsign: 'COLDBEARING',
    address: '0x3b71...9ae0',
    allTime: { wins: 35, losses: 33, streak: 'W1' },
    season: { wins: 11, losses: 12, streak: 'L1' },
    week: { wins: 1, losses: 2, streak: 'L1' },
  },
  {
    callsign: 'SILENTKEEL',
    address: '0x1e6d...88a3',
    allTime: { wins: 33, losses: 34, streak: 'L3' },
    season: { wins: 10, losses: 12, streak: 'L2' },
    week: { wins: 1, losses: 2, streak: 'L2' },
  },
  {
    callsign: 'GHOSTFATHOM',
    address: '0x772f...b0c6',
    allTime: { wins: 31, losses: 35, streak: 'W1' },
    season: { wins: 10, losses: 13, streak: 'W1' },
    week: { wins: 1, losses: 2, streak: 'W1' },
  },
  {
    callsign: 'TIDEBREAK',
    address: '0xa413...7d92',
    allTime: { wins: 29, losses: 37, streak: 'L1' },
    season: { wins: 9, losses: 13, streak: 'L1' },
    week: { wins: 1, losses: 3, streak: 'L1' },
  },
  {
    callsign: 'LOWSONAR',
    address: '0x5c8e...e451',
    allTime: { wins: 27, losses: 39, streak: 'W2' },
    season: { wins: 9, losses: 14, streak: 'W1' },
    week: { wins: 1, losses: 3, streak: 'W1' },
  },
  {
    callsign: 'BLACKFATHOM',
    address: '0x902b...3c1a',
    allTime: { wins: 25, losses: 41, streak: 'L2' },
    season: { wins: 8, losses: 15, streak: 'L1' },
    week: { wins: 0, losses: 3, streak: 'L2' },
  },
  {
    callsign: 'NULLWAKE',
    address: '0x2d9f...a774',
    allTime: { wins: 23, losses: 43, streak: 'W1' },
    season: { wins: 7, losses: 15, streak: 'W1' },
    week: { wins: 1, losses: 3, streak: 'W1' },
  },
  {
    callsign: 'WHITEWATER',
    address: '0xd611...59fa',
    allTime: { wins: 21, losses: 45, streak: 'L1' },
    season: { wins: 7, losses: 16, streak: 'L1' },
    week: { wins: 0, losses: 4, streak: 'L1' },
  },
  {
    callsign: 'GRAYFATHOM',
    address: '0x486c...2e17',
    allTime: { wins: 19, losses: 47, streak: 'W1' },
    season: { wins: 6, losses: 16, streak: 'W1' },
    week: { wins: 1, losses: 3, streak: 'W1' },
  },
  {
    callsign: 'IRONSWELL',
    address: '0xb27e...9d43',
    allTime: { wins: 17, losses: 49, streak: 'L4' },
    season: { wins: 5, losses: 17, streak: 'L3' },
    week: { wins: 0, losses: 4, streak: 'L3' },
  },
  {
    callsign: 'STORMWAKE',
    address: '0x64a0...e8b6',
    allTime: { wins: 15, losses: 51, streak: 'W1' },
    season: { wins: 5, losses: 18, streak: 'W1' },
    week: { wins: 1, losses: 3, streak: 'W1' },
  },
  {
    callsign: 'BRINESONG',
    address: '0x3f95...1c22',
    allTime: { wins: 12, losses: 54, streak: 'L2' },
    season: { wins: 4, losses: 19, streak: 'L2' },
    week: { wins: 0, losses: 4, streak: 'L2' },
  },
  {
    callsign: 'HOLLOWMAST',
    address: '0x7a18...d640',
    allTime: { wins: 9, losses: 58, streak: 'L5' },
    season: { wins: 3, losses: 20, streak: 'L4' },
    week: { wins: 0, losses: 5, streak: 'L3' },
  },
]

export function computeWinRate(stats: PeriodStats): number {
  const total = stats.wins + stats.losses
  if (total === 0) return 0
  return Math.round((stats.wins / total) * 100)
}

/**
 * Ranked view of the roster for a given period: sorted by wins
 * descending, win rate as tiebreaker, numbered 1 through the length
 * of the roster. Pure function of the static roster above, so the
 * same period always produces the same order.
 */
export function getStandings(period: LeaderboardPeriod): StandingRow[] {
  const withRate = ROSTER.map((entry) => {
    const stats = entry[period]
    return {
      callsign: entry.callsign,
      address: entry.address,
      isYou: Boolean(entry.isYou),
      wins: stats.wins,
      losses: stats.losses,
      streak: stats.streak,
      winRate: computeWinRate(stats),
    }
  })

  withRate.sort((a, b) => {
    if (b.wins !== a.wins) return b.wins - a.wins
    return b.winRate - a.winRate
  })

  return withRate.map((row, i) => ({ ...row, rank: i + 1 }))
}

export interface FleetActivityStat {
  label: string
  value: string
  meterPercent: number
}

export const FLEET_ACTIVITY: FleetActivityStat[] = [
  { label: 'Matches played', value: '1,284', meterPercent: 78 },
  { label: 'Admirals ranked', value: '24', meterPercent: 60 },
  { label: 'Captains deployed', value: '5', meterPercent: 100 },
  { label: 'Avg duration', value: '6m 42s', meterPercent: 45 },
]

export const RECENT_ENGAGEMENTS: string[] = [
  'KESTREL DEFEATED DRIFTWOOD',
  'NIGHTJAR DEFEATED HOLLOWMAST',
  'ABYSSAL DEFEATED GRAYFATHOM',
  'MERIDIAN DEFEATED STORMWAKE',
  'TIDEBORNE DEFEATED BRINESONG',
  'LODESTONE DEFEATED WHITEWATER',
]
