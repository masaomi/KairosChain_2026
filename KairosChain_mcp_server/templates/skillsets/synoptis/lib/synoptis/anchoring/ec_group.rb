# frozen_string_literal: true

require 'digest'

module Synoptis
  module Anchoring
    # Pure-Ruby prime-order elliptic-curve group for the AUD-L4 ZK aggregate
    # reproducibility SPIKE (aud_l4_zk_aggregate_reproducibility_spike_design
    # v0.1). This is the FIRST nontrivial cryptographic construction in the
    # synoptis anchoring stack beyond "sha256 + Ed25519" (SDP-5 disclosed base):
    # the deliberate departure is new MATH, not new external code. Every field
    # and group operation is hand-rolled here and inspectable in Ruby; OpenSSL
    # is used ONLY as a correctness oracle in the tests, never on this path, so
    # the anchoring stack acquires no new runtime dependency.
    #
    # Curve = secp256k1 (a standard prime-order short-Weierstrass curve,
    # y^2 = x^3 + 7 over F_p). Cofactor is 1, so every non-identity point has
    # prime order N; scalars reduce mod N. The group is written additively:
    # the design memo's multiplicative "g^s * h^r" is "s*G + r*H" here.
    module EcGroup
      # secp256k1 domain parameters (public, standard).
      P  = 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE_FFFFFC2F
      A  = 0
      B  = 7
      N  = 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE_BAAEDCE6_AF48A03B_BFD25E8C_D0364141
      GX = 0x79BE667E_F9DCBBAC_55A06295_CE870B07_029BFCDB_2DCE28D9_59F2815B_16F81798
      GY = 0x483ADA77_26A3C465_5DA4FBFC_0E1108A8_FD17B448_A6855419_9C47D08F_FB10D4B8

      # Nothing-up-my-sleeve seed for the second generator H. Publishing the seed
      # is the binding requirement (SDP-5): H is derived deterministically by
      # try-and-increment hash-to-curve, so no party knows log_G(H). Anyone can
      # recompute H from this seed and check it lands on the curve.
      H_SEED = 'synoptis/sda-1/pedersen-generator-h/secp256k1/v1'

      # Compressed-point encoding markers (SEC1 style): 0x02/0x03 for finite
      # points by y-parity; a distinct one-byte token for the identity.
      IDENTITY_ENCODING = '00'
      HEX_POINT = /\A(00|0[23][a-f0-9]{64})\z/

      class GroupError < StandardError; end

      # Immutable affine point. The identity (point at infinity) is INFINITY,
      # represented by nil coordinates; it is the neutral element of add.
      class Point
        attr_reader :x, :y

        def initialize(x, y)
          @x = x
          @y = y
          freeze
        end

        def infinity?
          @x.nil?
        end

        def ==(other)
          other.is_a?(Point) && other.x == @x && other.y == @y
        end
        alias eql? ==

        def hash
          [@x, @y].hash
        end
      end

      INFINITY = Point.new(nil, nil)

      module_function

      # The standard base point G (order N).
      def g
        @g ||= Point.new(GX, GY)
      end

      # The second generator H, derived nothing-up-my-sleeve from H_SEED so that
      # log_G(H) is unknown (Pedersen binding requirement, SDP-5).
      def h
        @h ||= hash_to_curve(H_SEED)
      end

      # y^2 == x^3 + 7 (mod P). The identity is trivially "on" the curve.
      def on_curve?(pt)
        return true if pt.infinity?

        (pt.y * pt.y - (pt.x.pow(3, P) + B)) % P == 0
      end

      # Modular inverse via Fermat (P is prime): a^(P-2) mod P.
      def mod_inv(a)
        (a % P).pow(P - 2, P)
      end

      def negate(pt)
        return pt if pt.infinity?

        Point.new(pt.x, (P - pt.y) % P)
      end

      # Group law for a short-Weierstrass curve with A = 0.
      def add(pt1, pt2)
        return pt2 if pt1.infinity?
        return pt1 if pt2.infinity?

        x1 = pt1.x
        y1 = pt1.y
        x2 = pt2.x
        y2 = pt2.y
        if x1 == x2
          return INFINITY if (y1 + y2) % P == 0 # P + (-P) = O

          slope = (3 * x1 * x1) * mod_inv(2 * y1) % P # doubling (A = 0)
        else
          slope = (y2 - y1) * mod_inv(x2 - x1) % P
        end
        x3 = (slope * slope - x1 - x2) % P
        y3 = (slope * (x1 - x3) - y1) % P
        Point.new(x3, y3)
      end

      def subtract(pt1, pt2)
        add(pt1, negate(pt2))
      end

      # k * pt by double-and-add. Scalars reduce mod N (cofactor 1).
      def scalar_mul(k, pt)
        k %= N
        result = INFINITY
        addend = pt
        while k.positive?
          result = add(result, addend) if k.odd?
          addend = add(addend, addend)
          k >>= 1
        end
        result
      end

      # Compressed encoding: identity token, else 0x02/0x03 (y-parity) || x.
      def encode(pt)
        return IDENTITY_ENCODING if pt.infinity?

        prefix = pt.y.even? ? '02' : '03'
        prefix + pt.x.to_s(16).rjust(64, '0')
      end

      # Inverse of +encode+. Recovers y from x on the curve, selecting the
      # branch matching the encoded parity. Malformed or off-curve input raises.
      def decode(hex)
        s = hex.to_s
        raise GroupError, "point encoding #{s.inspect} is not a compressed secp256k1 point" unless s.match?(HEX_POINT)
        return INFINITY if s == IDENTITY_ENCODING

        prefix = s[0, 2]
        x = Integer(s[2, 64], 16)
        raise GroupError, 'x coordinate not in field' unless x < P

        rhs = (x.pow(3, P) + B) % P
        y = sqrt_mod(rhs)
        raise GroupError, 'no curve point for the given x (off-curve encoding)' if y.nil?

        y = P - y if y.even? ^ (prefix == '02')
        pt = Point.new(x, y)
        raise GroupError, 'decoded point is not on the curve' unless on_curve?(pt)

        pt
      end

      # Modular square root for P ≡ 3 (mod 4): r = v^((P+1)/4). Returns a root
      # or nil when v is a non-residue.
      def sqrt_mod(v)
        v %= P
        r = v.pow((P + 1) / 4, P)
        r * r % P == v ? r : nil
      end

      # Deterministic try-and-increment hash-to-curve. The x candidate is
      # SHA-256(seed | counter); the first counter whose candidate has a
      # square-root y yields H (canonicalized to even y). Public and replayable.
      def hash_to_curve(seed)
        counter = 0
        loop do
          x = Integer(Digest::SHA256.hexdigest("#{seed}|#{counter}"), 16) % P
          rhs = (x.pow(3, P) + B) % P
          y = sqrt_mod(rhs)
          if y
            y = P - y if y.odd? # canonical even-y representative
            pt = Point.new(x, y)
            return pt unless pt.infinity?
          end
          counter += 1
          raise GroupError, 'hash_to_curve exhausted the counter budget' if counter > 1000
        end
      end
    end
  end
end
