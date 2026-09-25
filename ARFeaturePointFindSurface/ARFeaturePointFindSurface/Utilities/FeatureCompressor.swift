//
//  FeatureCompressor.swift
//  ARFeaturePointFindSurface
//
//  Created by CurvSurf-SGKim on 8/28/25.
//

import Foundation
import simd

import DequeModule

import SwiftUI

final class FeatureCompressor {
    
    struct Statistics {
        var maxBinSize: Int = 0
        var maxBinCount: Int = 0
        var averageBinUsage: Float = 0.0
        var identifierUsage: Int = 0
    }
    
    private let maxIdentifierCount: Int
    private let maxPointBinSize: Int
    
    init(maxIdentifierCount: Int, maxPointBinSize: Int) {
        self.maxIdentifierCount = maxIdentifierCount
        self.maxPointBinSize = maxPointBinSize
    }
    
    private var identifierSet: Set<UInt64> = []
    private var identifierList: Deque<UInt64> = []
    private var pointBins: [UInt64: Deque<simd_float3>] = [:]
    private(set) var pointList: [UInt64: simd_float3] = [:]
    
    var updated: Bool = false
    
    func clear() {
        identifierSet.removeAll(keepingCapacity: true)
        identifierList.removeAll(keepingCapacity: true)
        pointBins.removeAll(keepingCapacity: true)
        pointList.removeAll(keepingCapacity: true)
    }
    
    func exportStatistics(_ statistics: inout Statistics) {
        let bins = pointBins.values
        let binCount = bins.map { $0.count }
        statistics.maxBinSize = binCount.max() ?? 0
        statistics.maxBinCount = binCount.count(where: { $0 == statistics.maxBinSize })
        statistics.averageBinUsage = Float(binCount.reduce(0, +)) / Float(binCount.count)
        statistics.identifierUsage = identifierList.count
    }
    
    func append(features points: [simd_float3], with identifiers: [UInt64]) {
        
        let count = min(points.count, identifiers.count)
        guard count > 0 else { return }
        
        for i in 0..<count {
            
            let id = identifiers[i]
            if identifierSet.insert(id).inserted {
                if identifierSet.count > maxIdentifierCount {
                    let removedID = identifierList.removeFirst()
                    identifierSet.remove(removedID)
                    pointBins.removeValue(forKey: removedID)
                    pointList.removeValue(forKey: removedID)
                }
                identifierList.append(id)
            }
            
            var bin = pointBins[id, default: []]
            let point = points[i]
            bin.append(point)
            if bin.count > maxPointBinSize {
                bin.removeFirst()
            }
            
            if bin.count >= 5 {
                let f = removeOutliersInGaussianDistribution(bin.map { simd_double3($0) }, 2.0)
                let p = f.reduce(.zero, +) / Double(f.count)
                pointList[id] = simd_float3(p)
            }
            
            pointBins[id] = bin
        }
        updated = true
    }
}

func calcAveragePoint<C>(_ points: C) -> simd_float3 where C: Collection, C.Element == simd_float3  {
    return simd_float3(points.map { simd_double3($0) }.reduce(.zero, +) / Double(points.count))
}

func calcAveragePoint<C>(_ points: C, threshold: Double) -> simd_float3 where C: Collection, C.Element == simd_float3 {
    let f = removeOutliersInMahalanobisDistance(points.map { simd_double3($0) }, threshold)
    let p = f.reduce(.zero, +) / Double(f.count)
    return simd_float3(p)
}

func removeOutliersInGaussianDistribution(_ points: [simd_double3], _ zScore: Double) -> [simd_double3] {
    
    let meanPoint = points.reduce(.zero, +) / Double(points.count)
    
    let distanceSquared = points.map { point in
        simd_distance_squared(point, meanPoint)
    }
    
    let variance = distanceSquared.reduce(0.0, +) / Double(distanceSquared.count)
    let thresholdSquared = zScore * zScore * variance
    
    var indicesToBeRemoved = IndexSet()
    for (index, distanceSquared) in distanceSquared.enumerated() {
        if distanceSquared > thresholdSquared {
            indicesToBeRemoved.insert(index)
        }
    }
    let rangesToBeRemoved = RangeSet(indicesToBeRemoved)
    return Array(points.removingSubranges(rangesToBeRemoved))
}

func removeOutliersInMahalanobisDistance(_ points: [simd_double3], _ chi2Threshold: Double) -> [simd_double3] {
    
    let meanPoint = points.reduce(.zero, +) / Double(points.count)
    
    let invCov = calcCovarianceMatrix(points, meanPoint).inverse
    
    var filtered = [simd_double3]()
    filtered.reserveCapacity(points.count)
    for point in points {
        let d = simd_double3(point) - meanPoint
        let t = invCov * d
        let d2 = dot(d, t)
        if d2 <= chi2Threshold {
            filtered.append(point)
        }
    }
    
    return filtered
}

fileprivate func calcCovarianceMatrix(_ points: [simd_double3], _ meanPoint: simd_double3) -> simd_double3x3 {
    
    var covariance: simd_double3x3 = .init(0.0)
    
    for point in points {
        let d = point - meanPoint
        covariance += simd_double3x3(d.x * d, d.y * d, d.z * d)
    }
    covariance *= (1.0 / Double(points.count - 1))
    
    let eps = 1e-12 * max(1.0, covariance[0, 0] + covariance[1, 1] + covariance[2, 2])
    covariance[0, 0] += eps
    covariance[1, 1] += eps
    covariance[2, 2] += eps
    return covariance
}

fileprivate func inverseStandardNormalCDF(_ pRaw: Double) -> Double {
    let p = min(max(pRaw, 1e-15), 1.0 - 1e-15)

    // Acklam coefficients
    let a: [Double] = [
        -3.969683028665376e+01,
         2.209460984245205e+02,
        -2.759285104469687e+02,
         1.383577518672690e+02,
        -3.066479806614716e+01,
         2.506628277459239e+00
    ]
    let b: [Double] = [
        -5.447609879822406e+01,
         1.615858368580409e+02,
        -1.556989798598866e+02,
         6.680131188771972e+01,
        -1.328068155288572e+01
    ]
    let c: [Double] = [
        -7.784894002430293e-03,
        -3.223964580411365e-01,
        -2.400758277161838e+00,
        -2.549732539343734e+00,
         4.374664141464968e+00,
         2.938163982698783e+00
    ]
    let d: [Double] = [
         7.784695709041462e-03,
         3.224671290700398e-01,
         2.445134137142996e+00,
         3.754408661907416e+00
    ]

    // Break-points
    let plow  = 0.02425
    let phigh = 1.0 - plow

    if p < plow {
        // lower region
        let q = sqrt(-2.0 * log(p))
        return (((((c[0]*q + c[1])*q + c[2])*q + c[3])*q + c[4])*q + c[5]) /
               ((((d[0]*q + d[1])*q + d[2])*q + d[3])*q + 1.0)
    } else if p > phigh {
        // upper region
        let q = sqrt(-2.0 * log(1.0 - p))
        return -(((((c[0]*q + c[1])*q + c[2])*q + c[3])*q + c[4])*q + c[5]) /
                 ((((d[0]*q + d[1])*q + d[2])*q + d[3])*q + 1.0)
    } else {
        // central region
        let q = p - 0.5
        let r = q*q
        return (((((a[0]*r + a[1])*r + a[2])*r + a[3])*r + a[4])*r + a[5]) * q /
               (((((b[0]*r + b[1])*r + b[2])*r + b[3])*r + b[4])*r + 1.0)
    }
}

func chiSquareQuantileApprox(p pRaw: Double, dof k: Double = 3.0) -> Double {
    let p = min(max(pRaw, 1e-15), 1.0 - 1e-15)
    let z = inverseStandardNormalCDF(p)         // z = Φ⁻¹(p)
    let a = 1.0 - 2.0 / (9.0 * k)
    let b = sqrt(2.0 / (9.0 * k))
    let t = a + b * z
    return k * t*t*t
}
