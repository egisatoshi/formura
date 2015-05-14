#include <algorithm>
#include <cmath>
#include <iostream>

using namespace std;

int i30(int a, int b, int c) {
  return (30&(1<<(4*a+2*b+c)))!=0;
}

float f30(float a, float b, float c) {
  return 2.0f*a*b*c-2.0f*a*b-b*c-2.0f*a*c+a+b+c;
}

const int N=100;
float pat[N];
float pat_sub[N];

int main () {
  for (int a = 0; a<2; ++a) {
    for (int b = 0; b<2; ++b) {
      for (int c = 0; c<2; ++c) {
        if(float(i30(a,b,c)) != f30(a,b,c) ) {
          cerr << a << b << c << "!!" << endl;
          cerr <<i30(a,b,c) << " " <<  f30(a,b,c)  << endl;
          return 1;
        }
      }
    }
  }
  cout << "ok." <<endl;

  for (int i=0;i<N;++i) {
    pat[i]=(int(sqrt(2.14*i)*i*i)%2==0 )?1.0f:0.0f;
  }

  while(true){

    for (int i=0;i<N;++i) {
      if(pat[i]==0) cout << " ";
      else if(pat[i]==1) cout << "8";
      else cout << "!";
    }
    cout << endl;
    pat[0]=pat[N-2];
    pat[N-1]=pat[1];
    for (int i=1;i<N-1;++i) {
      pat_sub[i]=f30(pat[i-1],pat[i],pat[i+1]);
    }
    swap(pat,pat_sub);
  }

  return 0;
}
