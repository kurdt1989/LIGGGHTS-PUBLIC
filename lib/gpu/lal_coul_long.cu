// **************************************************************************
//                               coul_long.cu
//                             -------------------
//                           Axel Kohlmeyer (Temple)
//
//  Device code for acceleration of the coul/long pair style
//
// __________________________________________________________________________
//    This file is part of the LAMMPS Accelerator Library (LAMMPS_AL)
// __________________________________________________________________________
//
//    begin                : July 2011
//    email                : a.kohlmeyer@temple.edu
// ***************************************************************************/

#ifdef NV_KERNEL
#include "lal_aux_fun1.h"
texture<float4> pos_tex;
texture<float> q_tex;
#ifndef _DOUBLE_DOUBLE
ucl_inline float4 fetch_pos(const int& i, const float4 *pos) 
  { return tex1Dfetch(pos_tex, i); }
ucl_inline float fetch_q(const int& i, const float *q) 
  { return tex1Dfetch(q_tex, i); }
#endif
#endif

__kernel void kernel_pair(__global numtyp4 *x_, __global numtyp4 *lj1,
                          __global numtyp4* lj3, const int lj_types,
                          __global numtyp *sp_cl_in, __global int *dev_nbor,
                          __global int *dev_packed, __global acctyp4 *ans,
                          __global acctyp *engv, const int eflag,
                          const int vflag, const int inum,
                          const int nbor_pitch, __global numtyp *q_,
                          const numtyp cut_coulsq, const numtyp qqrd2e,
                          const numtyp g_ewald, const int t_per_atom) {
  int tid, ii, offset;
  atom_info(t_per_atom,ii,tid,offset);

  __local numtyp sp_cl[4];
  sp_cl[0]=sp_cl_in[0];
  sp_cl[1]=sp_cl_in[1];
  sp_cl[2]=sp_cl_in[2];
  sp_cl[3]=sp_cl_in[3];

  acctyp e_coul=(acctyp)0;
  acctyp4 f;
  f.x=(acctyp)0; f.y=(acctyp)0; f.z=(acctyp)0;
  acctyp virial[6];
  for (int i=0; i<6; i++)
    virial[i]=(acctyp)0;

  if (ii<inum) {
    __global int *nbor, *list_end;
    int i, numj, n_stride;
    nbor_info(dev_nbor,dev_packed,nbor_pitch,t_per_atom,ii,offset,i,numj,
              n_stride,list_end,nbor);

    numtyp4 ix=fetch_pos(i,x_); //x_[i];
    numtyp qtmp=fetch_q(i,q_);

    for ( ; nbor<list_end; nbor+=n_stride) {
      int j=*nbor;

      numtyp factor_coul;
      factor_coul = (numtyp)1.0-sp_cl[sbmask(j)];
      j &= NEIGHMASK;

      numtyp4 jx=fetch_pos(j,x_); //x_[j];

      // Compute r12
      numtyp delx = ix.x-jx.x;
      numtyp dely = ix.y-jx.y;
      numtyp delz = ix.z-jx.z;
      numtyp rsq = delx*delx+dely*dely+delz*delz;

      if (rsq < cut_coulsq) {
	numtyp r2inv=ucl_recip(rsq);
	numtyp force, prefactor, _erfc;

	numtyp r = ucl_rsqrt(r2inv);
	numtyp grij = g_ewald * r;
	numtyp expm2 = ucl_exp(-grij*grij);
	numtyp t = ucl_recip((numtyp)1.0 + EWALD_P*grij);
	_erfc = t * (A1+t*(A2+t*(A3+t*(A4+t*A5)))) * expm2;
	prefactor = qqrd2e * qtmp*fetch_q(j,q_)/r;
	force = prefactor * (_erfc + EWALD_F*grij*expm2-factor_coul) * r2inv;

        f.x+=delx*force;
        f.y+=dely*force;
        f.z+=delz*force;

        if (eflag>0) {
	  e_coul += prefactor*(_erfc-factor_coul);
        }
        if (vflag>0) {
          virial[0] += delx*delx*force;
          virial[1] += dely*dely*force;
          virial[2] += delz*delz*force;
          virial[3] += delx*dely*force;
          virial[4] += delx*delz*force;
          virial[5] += dely*delz*force;
        }
      }

    } // for nbor

    // Reduce answers
    if (t_per_atom>1) {
      __local acctyp red_acc[6][BLOCK_PAIR];

      red_acc[0][tid]=f.x;
      red_acc[1][tid]=f.y;
      red_acc[2][tid]=f.z;
      red_acc[3][tid]=e_coul;

      for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
        if (offset < s) {
          for (int r=0; r<4; r++)
            red_acc[r][tid] += red_acc[r][tid+s];
        }
      }

      f.x=red_acc[0][tid];
      f.y=red_acc[1][tid];
      f.z=red_acc[2][tid];
      e_coul=red_acc[3][tid];

      if (vflag>0) {
        for (int r=0; r<6; r++)
          red_acc[r][tid]=virial[r];

        for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
          if (offset < s) {
            for (int r=0; r<6; r++)
              red_acc[r][tid] += red_acc[r][tid+s];
          }
        }

        for (int r=0; r<6; r++)
          virial[r]=red_acc[r][tid];
      }
    }

    // Store answers
    if (offset==0) {
      __global acctyp *ap1=engv+ii;
      if (eflag>0) {
        *ap1=(acctyp)0;
        ap1+=inum;
        *ap1=e_coul;
        ap1+=inum;
      }
      if (vflag>0) {
        for (int i=0; i<6; i++) {
          *ap1=virial[i];
          ap1+=inum;
        }
      }
      ans[ii]=f;
    }
  } // if ii
}

__kernel void kernel_pair_fast(__global numtyp4 *x_, __global numtyp4 *lj1_in,
                               __global numtyp4* lj3_in,
                               __global numtyp* sp_cl_in,
                               __global int *dev_nbor, __global int *dev_packed,
                               __global acctyp4 *ans, __global acctyp *engv,
                               const int eflag, const int vflag, const int inum,
                               const int nbor_pitch, __global numtyp *q_,
                               const numtyp cut_coulsq, const numtyp qqrd2e,
                               const numtyp g_ewald, const int t_per_atom) {
  int tid, ii, offset;
  atom_info(t_per_atom,ii,tid,offset);

  __local numtyp sp_cl[4];
  if (tid<4)
    sp_cl[tid]=sp_cl_in[tid];

  acctyp e_coul=(acctyp)0;
  acctyp4 f;
  f.x=(acctyp)0; f.y=(acctyp)0; f.z=(acctyp)0;
  acctyp virial[6];
  for (int i=0; i<6; i++)
    virial[i]=(acctyp)0;

  __syncthreads();

  if (ii<inum) {
    __global int *nbor, *list_end;
    int i, numj, n_stride;
    nbor_info(dev_nbor,dev_packed,nbor_pitch,t_per_atom,ii,offset,i,numj,
              n_stride,list_end,nbor);

    numtyp4 ix=fetch_pos(i,x_); //x_[i];
    numtyp qtmp=fetch_q(i,q_);

    for ( ; nbor<list_end; nbor+=n_stride) {
      int j=*nbor;

      numtyp factor_coul;
      factor_coul = (numtyp)1.0-sp_cl[sbmask(j)];
      j &= NEIGHMASK;

      numtyp4 jx=fetch_pos(j,x_); //x_[j];

      // Compute r12
      numtyp delx = ix.x-jx.x;
      numtyp dely = ix.y-jx.y;
      numtyp delz = ix.z-jx.z;
      numtyp rsq = delx*delx+dely*dely+delz*delz;

      if (rsq < cut_coulsq) {
	numtyp r2inv=ucl_recip(rsq);
	numtyp force, prefactor, _erfc;

	numtyp r = ucl_rsqrt(r2inv);
	numtyp grij = g_ewald * r;
	numtyp expm2 = ucl_exp(-grij*grij);
	numtyp t = ucl_recip((numtyp)1.0 + EWALD_P*grij);
	_erfc = t * (A1+t*(A2+t*(A3+t*(A4+t*A5)))) * expm2;
	prefactor = qqrd2e * qtmp*fetch_q(j,q_)/r;
	force = prefactor * (_erfc + EWALD_F*grij*expm2-factor_coul) * r2inv;

        f.x+=delx*force;
        f.y+=dely*force;
        f.z+=delz*force;

        if (eflag>0) {
	  e_coul += prefactor*(_erfc-factor_coul);
        }
        if (vflag>0) {
          virial[0] += delx*delx*force;
          virial[1] += dely*dely*force;
          virial[2] += delz*delz*force;
          virial[3] += delx*dely*force;
          virial[4] += delx*delz*force;
          virial[5] += dely*delz*force;
        }
      }

    } // for nbor

    // Reduce answers
    if (t_per_atom>1) {
      __local acctyp red_acc[6][BLOCK_PAIR];

      red_acc[0][tid]=f.x;
      red_acc[1][tid]=f.y;
      red_acc[2][tid]=f.z;
      red_acc[3][tid]=e_coul;

      for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
        if (offset < s) {
          for (int r=0; r<4; r++)
            red_acc[r][tid] += red_acc[r][tid+s];
        }
      }

      f.x=red_acc[0][tid];
      f.y=red_acc[1][tid];
      f.z=red_acc[2][tid];
      e_coul=red_acc[3][tid];

      if (vflag>0) {
        for (int r=0; r<6; r++)
          red_acc[r][tid]=virial[r];

        for (unsigned int s=t_per_atom/2; s>0; s>>=1) {
          if (offset < s) {
            for (int r=0; r<6; r++)
              red_acc[r][tid] += red_acc[r][tid+s];
          }
        }

        for (int r=0; r<6; r++)
          virial[r]=red_acc[r][tid];
      }
    }

    // Store answers
    if (offset==0) {
      __global acctyp *ap1=engv+ii;
      if (eflag>0) {
        *ap1=(acctyp)0;
        ap1+=inum;
        *ap1=e_coul;
        ap1+=inum;
      }
      if (vflag>0) {
        for (int i=0; i<6; i++) {
          *ap1=virial[i];
          ap1+=inum;
        }
      }
      ans[ii]=f;
    }
  } // if ii
}

