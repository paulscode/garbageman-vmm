/**
 * Dashboard Component
 * ===================
 * Monitoring dashboard with metrics, charts, and visualizations.
 * Shows sync progress, peer statistics, and resource usage.
 */

'use client';

import { useState, useEffect } from 'react';
import { cn } from '@/lib/utils';
import {
  LineChart,
  Line,
  PieChart,
  Pie,
  Cell,
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from 'recharts';

interface Instance {
  id: string;
  state: string;
  impl: string;
  network: string;
  peers: number;
  blocks: number;
  headers: number;
  progress: number;
  diskGb: number;
  peerBreakdown?: {
    libreRelay: number;
    knots: number;
    oldCore: number;
    newCore: number;
    other: number;
  };
}

interface DashboardProps {
  className?: string;
  authenticatedFetch: (url: string, options?: RequestInit) => Promise<Response>;
}

// Color scheme for charts
const COLORS = {
  primary: '#00D1FF',      // cyan (accent)
  secondary: '#8B5CF6',    // purple
  success: '#10B981',      // green
  warning: '#F59E0B',      // amber
  error: '#EF4444',        // red
  neutral: '#6B7280',      // gray
};

const PEER_COLORS = [
  COLORS.primary,    // newCore
  COLORS.secondary,  // oldCore
  COLORS.success,    // knots
  COLORS.warning,    // libreRelay
  COLORS.neutral,    // other
];

export function Dashboard({ className, authenticatedFetch }: DashboardProps) {
  const [instances, setInstances] = useState<Instance[]>([]);
  const [loading, setLoading] = useState(true);

  // Fetch instances
  useEffect(() => {
    const fetchInstances = async () => {
      try {
        const response = await authenticatedFetch('http://localhost:8080/api/instances');
        const data = await response.json();
        // Map the API response to flat instance objects
        const flatInstances = (data.instances || []).map((item: any) => ({
          ...item.status,
          // Ensure state is consistent ('up' -> 'running')
          state: item.status.state === 'up' ? 'running' : item.status.state,
        }));
        setInstances(flatInstances);
        setLoading(false);
      } catch (error) {
        console.error('Failed to fetch instances:', error);
        setLoading(false);
      }
    };

    fetchInstances();
    const interval = setInterval(fetchInstances, 5000); // Update every 5s

    return () => clearInterval(interval);
  }, []);

  // Calculate aggregate metrics
  const totalInstances = instances.length;
  const runningInstances = instances.filter(i => i.state === 'running').length;
  const totalPeers = instances.reduce((sum, i) => sum + (i.peers || 0), 0);
  const avgProgress = instances.length > 0
    ? instances.reduce((sum, i) => sum + (i.progress || 0), 0) / instances.length
    : 0;
  const totalDiskGb = instances.reduce((sum, i) => sum + (i.diskGb || 0), 0);

  // Prepare sync progress data for chart
  const syncData = instances
    .filter(instance => instance && instance.id)
    .map(instance => ({
      name: instance.id.substring(5, 16), // Shorten to show just date-time portion
      fullName: instance.id,
      progress: parseFloat((instance.progress * 100).toFixed(2)),
      blocks: instance.blocks,
      headers: instance.headers,
    }));

  // Prepare peer breakdown data
  const peerData = instances.reduce((acc: any[], instance) => {
    if (instance.peerBreakdown) {
      const breakdown = instance.peerBreakdown;
      acc.push(
        { name: 'Core v30+', value: breakdown.newCore },
        { name: 'Old Core', value: breakdown.oldCore },
        { name: 'Knots', value: breakdown.knots },
        { name: 'LibreRelay', value: breakdown.libreRelay },
        { name: 'Other', value: breakdown.other }
      );
    }
    return acc;
  }, []);

  // Aggregate peer breakdown across all instances
  const aggregatePeerData = peerData.reduce((acc: any, curr) => {
    const existing = acc.find((item: any) => item.name === curr.name);
    if (existing) {
      existing.value += curr.value;
    } else {
      acc.push({ ...curr });
    }
    return acc;
  }, []).filter((item: any) => item.value > 0);

  if (loading) {
    return (
      <div className={cn('p-6 space-y-6', className)}>
        <div className="text-center text-tx3 font-mono">Loading dashboard...</div>
      </div>
    );
  }

  return (
    <div className={cn('p-6 space-y-6', className)}>
      {/* Header */}
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold font-mono text-tx0 uppercase">
          System Dashboard
        </h1>
        <div className="text-xs text-tx3 font-mono">
          {new Date().toLocaleString()}
        </div>
      </div>

      {/* KPI Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        <MetricCard
          title="Total Instances"
          value={totalInstances}
          subtitle={`${runningInstances} running`}
          color="primary"
        />
        <MetricCard
          title="Total Peers"
          value={totalPeers}
          subtitle={`Avg ${(totalPeers / Math.max(runningInstances, 1)).toFixed(1)} per instance`}
          color="success"
        />
        <MetricCard
          title="Avg Sync Progress"
          value={`${(avgProgress * 100).toFixed(1)}%`}
          subtitle="Across all instances"
          color="warning"
        />
        <MetricCard
          title="Disk Usage"
          value={`${totalDiskGb.toFixed(1)} GB`}
          subtitle="Total blockchain data"
          color="secondary"
        />
      </div>

      {/* Charts Grid */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Sync Progress Chart */}
        <ChartCard title="Sync Progress by Instance">
          <ResponsiveContainer width="100%" height={300}>
            <AreaChart data={syncData}>
              <CartesianGrid strokeDasharray="3 3" stroke="#333" />
              <XAxis
                dataKey="name"
                stroke="#6B7280"
                tick={{ fill: '#9CA3AF', fontSize: 10 }}
                angle={-45}
                textAnchor="end"
                height={80}
              />
              <YAxis
                stroke="#6B7280"
                tick={{ fill: '#9CA3AF', fontSize: 11 }}
                domain={[0, 100]}
                label={{ value: 'Progress (%)', angle: -90, position: 'insideLeft', fill: '#9CA3AF' }}
              />
              <Tooltip
                contentStyle={{
                  backgroundColor: '#1F2937',
                  border: '1px solid #374151',
                  borderRadius: '4px',
                  color: '#F9FAFB',
                }}
                formatter={(value: any, name: string) => {
                  if (name === 'progress') return [`${value}%`, 'Progress'];
                  return [value, name];
                }}
              />
              <Area
                type="monotone"
                dataKey="progress"
                stroke={COLORS.primary}
                fill={COLORS.primary}
                fillOpacity={0.3}
              />
            </AreaChart>
          </ResponsiveContainer>
        </ChartCard>

        {/* Peer Breakdown Chart */}
        <ChartCard title="Peer Type Distribution">
          {aggregatePeerData.length > 0 ? (
            <ResponsiveContainer width="100%" height={300}>
              <PieChart>
                <Pie
                  data={aggregatePeerData}
                  cx="50%"
                  cy="50%"
                  labelLine={false}
                  label={({ name, percent }) => `${name}: ${(percent * 100).toFixed(0)}%`}
                  outerRadius={80}
                  fill="#8884d8"
                  dataKey="value"
                >
                  {aggregatePeerData.map((entry: any, index: number) => (
                    <Cell key={`cell-${index}`} fill={PEER_COLORS[index % PEER_COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{
                    backgroundColor: '#1F2937',
                    border: '1px solid #374151',
                    borderRadius: '4px',
                    color: '#F9FAFB',
                  }}
                />
              </PieChart>
            </ResponsiveContainer>
          ) : (
            <div className="flex items-center justify-center h-[300px] text-tx3 font-mono text-sm">
              No peer data available
            </div>
          )}
        </ChartCard>
      </div>

      {/* Instance Details Table */}
      <div className="border border-subtle rounded bg-bg1 overflow-hidden">
        <div className="px-4 py-3 border-b border-subtle bg-bg2">
          <h2 className="text-sm font-bold font-mono text-tx0 uppercase">
            Instance Details
          </h2>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full font-mono text-xs">
            <thead className="bg-bg2 text-tx2">
              <tr>
                <th className="px-4 py-2 text-left">ID</th>
                <th className="px-4 py-2 text-left">State</th>
                <th className="px-4 py-2 text-left">Network</th>
                <th className="px-4 py-2 text-right">Peers</th>
                <th className="px-4 py-2 text-right">Progress</th>
                <th className="px-4 py-2 text-right">Blocks</th>
                <th className="px-4 py-2 text-right">Disk</th>
              </tr>
            </thead>
            <tbody className="text-tx1">
              {instances.map((instance) => (
                <tr key={instance.id} className="border-t border-subtle hover:bg-bg2 transition-colors">
                  <td className="px-4 py-2">{instance.id || 'N/A'}</td>
                  <td className="px-4 py-2">
                    <span className={cn(
                      'px-2 py-0.5 rounded text-xs font-bold',
                      instance.state === 'running' ? 'bg-green/20 text-green' : 'bg-subtle text-tx3'
                    )}>
                      {instance.state ? instance.state.toUpperCase() : 'UNKNOWN'}
                    </span>
                  </td>
                  <td className="px-4 py-2">{instance.network || 'N/A'}</td>
                  <td className="px-4 py-2 text-right">{instance.peers || 0}</td>
                  <td className="px-4 py-2 text-right">{((instance.progress || 0) * 100).toFixed(2)}%</td>
                  <td className="px-4 py-2 text-right">{(instance.blocks || 0).toLocaleString()}</td>
                  <td className="px-4 py-2 text-right">{(instance.diskGb || 0).toFixed(1)} GB</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

// Metric Card Component
interface MetricCardProps {
  title: string;
  value: string | number;
  subtitle?: string;
  color: keyof typeof COLORS;
}

function MetricCard({ title, value, subtitle, color }: MetricCardProps) {
  const colorClass = {
    primary: 'border-accent text-accent',
    secondary: 'border-purple-500 text-purple-500',
    success: 'border-green text-green',
    warning: 'border-amber-500 text-amber-500',
    error: 'border-red text-red',
    neutral: 'border-subtle text-tx2',
  }[color];

  return (
    <div className={cn(
      'p-4 rounded border bg-bg1 transition-all hover:scale-[1.02]',
      colorClass
    )}>
      <div className="text-xs font-mono text-tx3 uppercase mb-2">
        {title}
      </div>
      <div className="text-2xl font-bold font-mono mb-1">
        {value}
      </div>
      {subtitle && (
        <div className="text-xs font-mono text-tx3">
          {subtitle}
        </div>
      )}
    </div>
  );
}

// Chart Card Component
interface ChartCardProps {
  title: string;
  children: React.ReactNode;
}

function ChartCard({ title, children }: ChartCardProps) {
  return (
    <div className="border border-subtle rounded bg-bg1 overflow-hidden">
      <div className="px-4 py-3 border-b border-subtle bg-bg2">
        <h2 className="text-sm font-bold font-mono text-tx0 uppercase">
          {title}
        </h2>
      </div>
      <div className="p-4">
        {children}
      </div>
    </div>
  );
}
